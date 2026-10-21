using DataFrames, Dates
using MultiScaleTreeGraph
isdefined(@__MODULE__, :load_yearly_scene) || include("saved_simulation.jl")

function _integrated_plant_days!(con, metadata; config_id)
    get(metadata, "config_id", nothing) == config_id ||
        throw(ArgumentError("The saved manifest has a different configuration ID."))
    columns = propertynames(DataFrame(DBInterface.execute(con, "SELECT * FROM plants LIMIT 0")))
    required = (:datetime, :plant_instance_id, :leaf_area, :assimilation_step)
    all(column -> column in columns, required) || throw(ArgumentError(
        "Cycle integration requires saved plant timestamps, stable plant_instance_id, leaf area and timestep assimilation."))
    days = Date.(metadata["days"])
    isempty(days) && throw(ArgumentError("The saved simulation has no days."))
    length(unique(days)) == length(days) || throw(ArgumentError("Repeated saved simulation days."))
    DBInterface.execute(con, """
        CREATE TEMP TABLE plant_days AS
        SELECT CAST(datetime AS DATE) AS day, plant_instance_id,
            avg(leaf_area) AS leaf_area, min(leaf_area) AS minimum_area,
            max(leaf_area) AS maximum_area,
            sum(assimilation_step) AS assimilation_umol_CO2,
            count(*) AS n_steps, count(DISTINCT datetime) AS distinct_steps,
            count(*) FILTER (WHERE plant_instance_id IS NULL OR leaf_area IS NULL
                OR NOT isfinite(leaf_area) OR leaf_area < 0 OR assimilation_step IS NULL
                OR NOT isfinite(assimilation_step)) AS invalid_rows
        FROM plants GROUP BY 1, 2
        """)
    observed_days = DataFrame(DBInterface.execute(con, "SELECT DISTINCT day FROM plant_days ORDER BY day")).day
    sort(days) == observed_days || throw(ArgumentError("Plant outputs do not cover the saved simulation days."))
    invalid = only(DataFrame(DBInterface.execute(con, """
        SELECT count(*) AS n FROM plant_days p JOIN (
            SELECT CAST(datetime AS DATE) AS day, count(DISTINCT datetime) AS expected_steps
            FROM plants GROUP BY 1) t USING (day)
        WHERE p.invalid_rows > 0 OR p.n_steps != p.distinct_steps
            OR p.n_steps != t.expected_steps
            OR abs(p.maximum_area - p.minimum_area) > 1e-10
        """)).n)
    invalid == 0 || throw(ArgumentError("Invalid, repeated or incomplete plant timesteps, or changing leaf area within a saved daily scene."))
    incomplete = only(DataFrame(DBInterface.execute(con, """
        SELECT count(*) AS n FROM (
            SELECT plant_instance_id FROM plant_days GROUP BY plant_instance_id
            HAVING count(*) != $(length(days)))
        """)).n)
    incomplete == 0 || throw(ArgumentError("Planting positions do not cover the complete saved simulation period."))
    if haskey(metadata, "scenes")
        expected = Dict(Date(entry["scene"]["day"]) =>
            length(entry["scene"]["plant_rotations_rad"]) for entry in metadata["scenes"])
        length(expected) == length(metadata["scenes"]) == length(days) && Set(keys(expected)) == Set(days) ||
            throw(ArgumentError("Saved scene recipes differ from the simulated period."))
        populations = DataFrame(DBInterface.execute(con,
            "SELECT day, count(*) AS n_plants FROM plant_days GROUP BY day"))
        all(row -> row.n_plants == expected[row.day], eachrow(populations)) ||
            throw(ArgumentError("Plant outputs omit or repeat positions from the saved planting layout."))
    end
    return days
end

"""Sum all signed, area-integrated timestep assimilation per planting position (mol CO₂)."""
function integrated_plant_assimilation(; config_id, output_dir=_agripv_yearly_output_dir())
    with_saved_outputs(; config_id, tables=:plants, input_dir=output_dir) do con, metadata
        _integrated_plant_days!(con, metadata; config_id)
        result = DataFrame(DBInterface.execute(con, """
            SELECT plant_instance_id, sum(assimilation_umol_CO2) / 1e6 AS total_assimilation
            FROM plant_days GROUP BY plant_instance_id ORDER BY plant_instance_id
            """))
        all(x -> !ismissing(x), result.plant_instance_id) ||
            throw(ArgumentError("Stable planting IDs are required for cycle aggregation."))
        all(x -> !ismissing(x) && isfinite(x), result.total_assimilation) ||
            throw(ArgumentError("Invalid integrated assimilation values."))
        return result
    end
end

"""
    integrated_plant_outputs(; config_id, output_dir=..., photons_per_J=4.57)

Integrate saved green-leaf absorption and signed plant assimilation over the
complete growth cycle. Read retained Parquet and timestep durations; no physics
is rerun. Return leaf-area-normalized photons (mol/m²), total photons (mol/plant)
and net assimilation (mol CO₂/plant), keyed by stable `plant_instance_id`.
"""
function integrated_plant_outputs(; config_id, output_dir=_agripv_yearly_output_dir(), photons_per_J=4.57)
    isfinite(photons_per_J) && photons_per_J > 0 || throw(ArgumentError("photons_per_J must be positive and finite."))
    with_saved_outputs(; config_id, tables=(:plants, :light, :forcing), input_dir=output_dir) do con, metadata
        _integrated_plant_days!(con, metadata; config_id)
        invalid_forcing = only(DataFrame(DBInterface.execute(con, """
            SELECT count(*) - count(DISTINCT date) +
                count(*) FILTER (WHERE date IS NULL OR duration IS NULL
                    OR NOT isfinite(duration) OR duration <= 0) AS n FROM forcing
            """)).n)
        invalid_forcing == 0 || throw(ArgumentError("Saved forcing has invalid or repeated timestep durations."))
        mismatched_dates = only(DataFrame(DBInterface.execute(con, """
            SELECT count(*) AS n FROM (
                (SELECT DISTINCT datetime FROM plants EXCEPT SELECT date FROM forcing)
                UNION ALL
                (SELECT date FROM forcing EXCEPT SELECT DISTINCT datetime FROM plants))
            """)).n)
        mismatched_dates == 0 || throw(ArgumentError("Saved plant and forcing timestamps differ."))
        DBInterface.execute(con, """
            CREATE TEMP TABLE absorbed_steps AS
            SELECT CAST(l.datetime AS DATE) AS day, l.datetime, l.plant_instance_id,
                sum(l.Ra_PAR_f * l.area * f.duration) AS absorbed_PAR_J,
                sum(l.area) AS leaf_area, count(*) AS organ_rows,
                count(DISTINCT l.node_id) AS distinct_organs,
                count(*) FILTER (WHERE l.node_id IS NULL OR l.plant_instance_id IS NULL OR f.date IS NULL
                    OR l.Ra_PAR_f IS NULL OR NOT isfinite(l.Ra_PAR_f) OR l.Ra_PAR_f < 0
                    OR l.area IS NULL OR NOT isfinite(l.area) OR l.area < 0) AS invalid_rows
            FROM light l LEFT JOIN forcing f ON l.datetime = f.date
            WHERE l.scale = 'LeafSection' AND l.kind = 'active_leaf'
            GROUP BY 1, 2, 3
            """)
        invalid_steps = only(DataFrame(DBInterface.execute(con, """
            SELECT count(*) AS n FROM absorbed_steps e LEFT JOIN plant_days p USING (day, plant_instance_id)
            WHERE e.invalid_rows > 0 OR e.organ_rows != e.distinct_organs OR p.day IS NULL
                OR abs(e.leaf_area - p.leaf_area) > 1e-8 * greatest(1, p.leaf_area)
            """)).n)
        invalid_steps == 0 || throw(ArgumentError("Saved green-leaf radiation has repeated nodes or different identities/areas from plant outputs."))
        DBInterface.execute(con, """
            CREATE TEMP TABLE absorbed_days AS
            SELECT day, plant_instance_id, sum(absorbed_PAR_J) AS absorbed_PAR_J, count(*) AS n_steps
            FROM absorbed_steps GROUP BY day, plant_instance_id
            """)
        invalid_energy = only(DataFrame(DBInterface.execute(con, """
            SELECT count(*) AS n FROM absorbed_days e
            LEFT JOIN plant_days p USING (day, plant_instance_id)
            WHERE p.day IS NULL OR e.n_steps != p.n_steps
                OR NOT isfinite(e.absorbed_PAR_J)
                OR (p.leaf_area = 0 AND e.absorbed_PAR_J > 1e-10)
            """)).n)
        invalid_energy == 0 || throw(ArgumentError("Saved green-leaf absorption differs from plant identities, dates or timesteps."))
        absent_energy = only(DataFrame(DBInterface.execute(con, """
            SELECT count(*) AS n FROM plant_days p
            LEFT JOIN absorbed_days e USING (day, plant_instance_id)
            WHERE p.leaf_area > 0 AND e.day IS NULL
            """)).n)
        absent_energy == 0 || throw(ArgumentError("Absorbed light outputs are missing for a green planting position."))
        result = DataFrame(DBInterface.execute(con, """
            SELECT $config_id AS config_id, plant_instance_id, count(*) AS n_days,
                sum(CASE WHEN p.leaf_area > 0 THEN coalesce(e.absorbed_PAR_J, 0) / p.leaf_area
                    ELSE 0 END) * $photons_per_J / 1e6 AS cumulative_appfd_mol_m2,
                sum(coalesce(e.absorbed_PAR_J, 0)) * $photons_per_J / 1e6 AS absorbed_photons_mol_plant,
                sum(p.assimilation_umol_CO2) / 1e6 AS net_assimilation_mol_CO2_plant
            FROM plant_days p LEFT JOIN absorbed_days e USING (day, plant_instance_id)
            GROUP BY plant_instance_id ORDER BY plant_instance_id
            """))
        for column in (:cumulative_appfd_mol_m2, :absorbed_photons_mol_plant, :net_assimilation_mol_CO2_plant)
            all(x -> !ismissing(x) && isfinite(x), result[!, column]) ||
                throw(ArgumentError("Invalid integrated values in $column."))
        end
        return result
    end
end

"""Regenerate small cumulative CSVs and a checksum manifest from retained outputs."""
function write_integrated_plant_outputs(; config_ids=0:3, output_dir=_agripv_yearly_output_dir(),
    summary_dir=joinpath(_agripv_project_root(), "2_outputs", "cumulative_appfd"), photons_per_J=4.57)
    config_ids = collect(config_ids)
    isempty(config_ids) && throw(ArgumentError("Select at least one configuration."))
    length(unique(config_ids)) == length(config_ids) || throw(ArgumentError("Repeated configuration IDs."))
    mkpath(summary_dir)
    summaries = Dict{Int,DataFrame}()
    entries = Dict{String,Any}[]
    reference_days = nothing
    for config_id in config_ids
        metadata_path = joinpath(output_dir, "scene_config_$(config_id).toml")
        metadata = TOML.parsefile(metadata_path)
        days = metadata["days"]
        if isnothing(reference_days)
            reference_days = days
        else
            days == reference_days || throw(ArgumentError("Configuration periods differ."))
        end
        @info "Integrating retained plant and light outputs" config_id
        table = integrated_plant_outputs(; config_id, output_dir, photons_per_J)
        path = joinpath(summary_dir, "plants_config_$(config_id).csv")
        CSV.write(path, table)
        push!(entries, Dict("config_id" => config_id, "days" => days,
            "source_metadata" => relpath(metadata_path, _agripv_project_root()),
            "source_metadata_sha256" => _agripv_saved_file_sha256(metadata_path),
            "output_file" => basename(path), "output_sha256" => _agripv_saved_file_sha256(path),
            "forcing_origin" => get(metadata, "forcing_origin", "saved")))
        summaries[config_id] = table
    end
    provenance = Dict("recipe_version" => 2, "identity" => "plant_instance_id within configuration",
        "radiation_scope" => "active green LeafSection only", "photons_per_J" => photons_per_J,
        "leaf_mean_formula" => "sum_day(sum_green_leaf(Ra_PAR_f * area * duration_s) / green_leaf_area_day) * photons_per_J / 1e6",
        "photons_formula" => "sum_green_leaf_timesteps(Ra_PAR_f * area * duration_s) * photons_per_J / 1e6",
        "assimilation_formula" => "sum_plant_timesteps(assimilation_step) / 1e6; signed values retained",
        "units" => Dict("cumulative_appfd_mol_m2" => "mol photons m^-2 green leaf area",
            "absorbed_photons_mol_plant" => "mol photons plant^-1",
            "net_assimilation_mol_CO2_plant" => "mol CO2 plant^-1"), "configs" => entries)
    open(joinpath(summary_dir, "provenance.toml"), "w") do io
        TOML.print(io, provenance)
    end
    return summaries
end

"""Reconstruct saved yearly geometry and attach cycle-total mol CO₂ to each plant and its organs."""
function attach_assimilation_to_yearly_scene(config_id, day; output_dir=_agripv_yearly_output_dir())
    totals = integrated_plant_assimilation(; config_id, output_dir)
    values = Dict(Int(row.plant_instance_id) => row.total_assimilation for row in eachrow(totals))
    scene = load_yearly_scene(; config_id, day, output_dir).scene
    present = Set{Int}()
    MultiScaleTreeGraph.traverse!(scene.mtg) do node
        symbol(node) == :Plant && push!(present, Int(node[:plantID]))
    end
    present == Set(keys(values)) || throw(ArgumentError("Integrated planting IDs differ from saved geometry."))
    function attach!(node, id=nothing)
        symbol(node) == :Plant && (id = Int(node[:plantID]))
        node[:total_assimilation] = isnothing(id) ? nothing : values[id]
        foreach(child -> attach!(child, id), children(node))
    end
    attach!(scene.mtg)
    return scene
end
