using Dates, DataFrames

isdefined(@__MODULE__, :with_saved_outputs) || include("parquet_output_io.jl")

function _validate_year_assimilation_outputs(con, metadata, config_id, input_dir; verify_hash=true)
    get(metadata, "simulation", nothing) == "growth_period" && metadata["config_id"] == config_id ||
        throw(ArgumentError("Expected growth-period metadata for configuration $config_id."))
    get(metadata, "plant_instance_identity_scope", nothing) == "configuration" ||
        throw(ArgumentError("Annual per-plant curves require persistent plant_instance_id across saved days."))
    coverage = DataFrame(DBInterface.execute(con, """
        SELECT datetime, count(*) AS source_rows,
            count(DISTINCT plant_instance_id) AS distinct_plants,
            min(plant_instance_id) AS first_plant,
            count(*) FILTER (WHERE datetime IS NULL OR plant_instance_id IS NULL
                OR assimilation_step IS NULL OR NOT isfinite(assimilation_step)) AS invalid_rows
        FROM plants GROUP BY datetime ORDER BY datetime
        """))
    !isempty(coverage) && all(==(0), coverage.invalid_rows) ||
        throw(ArgumentError("Missing identity/timestamp or invalid assimilation step in configuration $config_id."))
    sum(coverage.source_rows) == metadata["tables"]["plants"]["rows"] ||
        throw(ArgumentError("Plant output row count differs from saved metadata for configuration $config_id."))
    scene_plants = Dict(Date(entry["scene"]["day"]) =>
        length(entry["scene"]["plant_rotations_rad"]) for entry in metadata["scenes"])
    length(scene_plants) == length(metadata["scenes"]) == length(metadata["days"]) &&
        allunique(metadata["days"]) ||
        throw(ArgumentError("Repeated scene or period dates in configuration $config_id."))
    Set(Date.(coverage.datetime)) == Set(Date.(metadata["days"])) == Set(keys(scene_plants)) ||
        throw(ArgumentError("Plant output dates differ from the saved growth period for configuration $config_id."))
    complete_positions = all(eachrow(coverage)) do row
        expected = scene_plants[Date(row.datetime)]
        row.source_rows == row.distinct_plants == expected && row.first_plant > 0
    end
    complete_positions ||
        throw(ArgumentError("Repeated or missing planting positions at a timestamp in configuration $config_id."))
    expected_counts = unique(collect(values(scene_plants)))
    if length(expected_counts) == 1
        cycle_positions = only(DataFrame(DBInterface.execute(con,
            "SELECT count(DISTINCT plant_instance_id) AS positions FROM plants")).positions)
        cycle_positions == only(expected_counts) ||
            throw(ArgumentError("Persistent planting identities change within configuration $config_id."))
    end
    if haskey(metadata, "forcing")
        saved_forcing = _agripv_read_parquet(input_dir, metadata["forcing"]; variables=[:date], verify_hash)
        Set(coverage.datetime) == Set(DateTime.(saved_forcing.date)) ||
            throw(ArgumentError("Plant output timestamps differ from saved forcing for configuration $config_id."))
    end
    return coverage
end

"""
    summarize_year_assimilation(; config_id, input_dir=..., curve_sampling=:daily,
        verify_hash=true)

Read all saved planting instances and integrate their signed `assimilation_step`
values (μmol CO₂ per plant per step) over the entire growth period. No duration
factor is applied again and negative steps are retained. Ignore the archived
`assimilation_cumulative`, which may reset each day.

Return `individual` curves, `whole_crop` hourly totals and `coverage` validation
counts. For `curve_sampling=:daily`, every saved hourly step contributes to the
integration, while individual curves retain only each day's last timestamp.
Use `:hourly` to retain all vertices. Daily endpoint sampling bounds plotting
memory and preserves each plant's final cumulative value.

Checksums, source row count, scene dates and planting counts, duplicate/null
identities, finite signed steps, stable cross-day identities and saved forcing
timestamp coverage are checked before integration. No simulation is run.
"""
function summarize_year_assimilation(; config_id,
    input_dir=joinpath(@__DIR__, "..", "2_outputs", "simulations", "yearly"),
    curve_sampling=:daily, verify_hash=true)
    curve_sampling in (:daily, :hourly) ||
        throw(ArgumentError("curve_sampling must be :daily or :hourly."))
    return with_saved_outputs(; config_id, tables=:plants, input_dir, verify_hash) do con, metadata
        coverage = _validate_year_assimilation_outputs(con, metadata, config_id, input_dir; verify_hash)
        curve_source = curve_sampling == :daily ? """
            (SELECT plant_instance_id, max(datetime) AS datetime,
                sum(assimilation_step) AS assimilation_step
             FROM plants GROUP BY plant_instance_id, CAST(datetime AS DATE))
            """ : "plants"
        individual = DataFrame(DBInterface.execute(con, """
            SELECT $(Int(config_id)) AS configID, plant_instance_id, datetime,
                sum(assimilation_step) OVER (
                    PARTITION BY plant_instance_id ORDER BY datetime
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS assimilation_cumulative
            FROM $curve_source ORDER BY plant_instance_id, datetime
            """))
        whole_crop = DataFrame(DBInterface.execute(con, """
            SELECT $(Int(config_id)) AS configID, datetime,
                sum(step_sum) OVER (ORDER BY datetime
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS assimilation_cumulative_sum
            FROM (SELECT datetime, sum(assimilation_step) AS step_sum
                  FROM plants GROUP BY datetime) ORDER BY datetime
            """))
        return (; individual, whole_crop, coverage, curve_sampling)
    end
end
