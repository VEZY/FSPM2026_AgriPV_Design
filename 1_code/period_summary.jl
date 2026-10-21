using CSV, DataFrames, Dates, Printf, SHA, TOML
isdefined(@__MODULE__, :summarize_year_assimilation) || include("yearly_assimilation_plotting.jl")

const AGRIPV_PERIOD_QUANTITIES = (
    (quantity="net_assimilation", label="Net assimilation", unit="mol CO2",
        formula="sum(assimilation_step) / 1e6", scope="green leaf sections; signed net CO2 exchange"),
    (quantity="absorbed_PAR", label="Absorbed PAR energy", unit="J",
        formula="sum_plant_organs(Ra_PAR_f * area * duration_s)",
        scope="all plant organs, including green and senescent leaves and stems; excludes soil and panels"),
    (quantity="transpiration", label="Transpiration", unit="kg H2O",
        formula="sum(transpiration_step)", scope="positive green-leaf water exchange"),
    (quantity="net_water_exchange", label="Net water exchange", unit="kg H2O",
        formula="sum(net_water_flux * duration_s)", scope="signed transpiration minus condensation"),
)

const AGRIPV_PERIOD_TEMPERATURES = (
    (quantity="leaf_temperature_mean", label="Leaf temperature, area/time weighted mean", unit="degC",
        formula="sum(T_l_mean * green_leaf_area * duration_s) / sum(green_leaf_area * duration_s)",
        scope="green leaf sections across all plants and saved timesteps", aggregation="area-and-time-weighted mean"),
    (quantity="leaf_temperature_min", label="Leaf temperature, minimum", unit="degC",
        formula="min(T_l_min) where green_leaf_area > 0", scope="positive-area green leaf sections", aggregation="minimum"),
    (quantity="leaf_temperature_max", label="Leaf temperature, maximum", unit="degC",
        formula="max(T_l_max) where green_leaf_area > 0", scope="positive-area green leaf sections", aggregation="maximum"),
)

_agripv_period_scalar(con, sql) = only(DataFrame(DBInterface.execute(con, sql)).n)

function _agripv_validate_period_forcing!(con, coverage, metadata)
    columns = propertynames(DataFrame(DBInterface.execute(con, "SELECT * FROM forcing LIMIT 0")))
    all(in(columns), (:date, :duration)) ||
        throw(ArgumentError("Period energy and water integration require saved forcing dates and durations in seconds."))
    invalid = _agripv_period_scalar(con, """
        SELECT count(*) - count(DISTINCT date) +
            count(*) FILTER (WHERE date IS NULL OR duration IS NULL
                OR NOT isfinite(duration) OR duration <= 0) AS n FROM forcing
        """)
    invalid == 0 || throw(ArgumentError("Saved forcing has invalid or repeated timestep durations."))
    forcing = DataFrame(DBInterface.execute(con,
        "SELECT date AS datetime, duration AS duration_s FROM forcing ORDER BY date"))
    nrow(forcing) == metadata["forcing"]["rows"] ||
        throw(ArgumentError("Saved forcing row count differs from its manifest."))
    forcing.datetime == coverage.datetime ||
        throw(ArgumentError("Plant outputs and saved forcing must have identical timestamps."))
    return forcing
end

function _agripv_period_plant_totals!(con, n_plants)
    columns = propertynames(DataFrame(DBInterface.execute(con, "SELECT * FROM plants LIMIT 0")))
    :transpiration_step in columns || throw(ArgumentError("Period water totals require retained transpiration_step."))
    optional = filter(in(columns), [:net_water_flux])
    invalid_terms = ["p.transpiration_step IS NULL OR NOT isfinite(p.transpiration_step) OR p.transpiration_step < 0"]
    for name in filter(in(columns), [:condensation, :net_water_flux])
        column = "p." * _agripv_sql_identifier(name)
        push!(invalid_terms, "$column IS NULL OR NOT isfinite($column)" *
            (name == :condensation ? " OR $column < 0" : ""))
    end
    if :transpiration in columns
        push!(invalid_terms, "p.transpiration IS NULL OR NOT isfinite(p.transpiration) OR p.transpiration < 0")
        push!(invalid_terms, "abs(p.transpiration_step - p.transpiration * f.duration) > 1e-10 * greatest(1, p.transpiration_step)")
        if all(in(columns), (:condensation, :net_water_flux))
            push!(invalid_terms, "abs(p.net_water_flux - p.transpiration + p.condensation) > 1e-10 * greatest(1, p.transpiration, p.condensation)")
        end
    end
    invalid = _agripv_period_scalar(con, """
        SELECT count(*) FILTER (WHERE $(join(invalid_terms, " OR "))) AS n
        FROM plants p JOIN forcing f ON p.datetime = f.date
        """)
    invalid == 0 || throw(ArgumentError("Invalid plant water totals or inconsistent rate/timestep water outputs."))
    extra_columns = join([", sum(p.$(_agripv_sql_identifier(name)) * f.duration) AS $(_agripv_sql_identifier(name))"
        for name in optional])
    DBInterface.execute(con, """
        CREATE TEMP TABLE period_plants AS
        SELECT p.plant_instance_id, sum(p.assimilation_step) / 1e6 AS net_assimilation,
            sum(p.transpiration_step) AS transpiration $extra_columns
        FROM plants p JOIN forcing f ON p.datetime = f.date
        GROUP BY p.plant_instance_id
        """)
    _agripv_period_scalar(con, "SELECT count(*) AS n FROM period_plants") == n_plants ||
        throw(ArgumentError("Plant identities change over the saved period."))
    return optional
end

function _agripv_period_temperatures(con)
    columns = propertynames(DataFrame(DBInterface.execute(con, "SELECT * FROM plants LIMIT 0")))
    names = (:leaf_area, :Tₗ_mean, :Tₗ_min, :Tₗ_max)
    all(in(columns), names) || throw(ArgumentError("Leaf temperature summaries require retained leaf area and plant mean/minimum/maximum leaf temperatures."))
    mean_T, min_T, max_T = _agripv_sql_identifier.((:Tₗ_mean, :Tₗ_min, :Tₗ_max))
    invalid = _agripv_period_scalar(con, """
        SELECT count(*) FILTER (WHERE leaf_area IS NULL OR NOT isfinite(leaf_area) OR leaf_area < 0
            OR (leaf_area > 0 AND ($mean_T IS NULL OR NOT isfinite($mean_T)
                OR $min_T IS NULL OR NOT isfinite($min_T) OR $max_T IS NULL OR NOT isfinite($max_T)
                OR $min_T > $mean_T + 1e-10 OR $mean_T > $max_T + 1e-10))) AS n FROM plants
        """)
    invalid == 0 || throw(ArgumentError("Invalid positive-area leaf temperatures or green-leaf areas."))
    result = DataFrame(DBInterface.execute(con, """
        SELECT sum(p.$mean_T * p.leaf_area * f.duration) / nullif(sum(p.leaf_area * f.duration), 0) AS leaf_temperature_mean,
            min(p.$min_T) AS leaf_temperature_min, max(p.$max_T) AS leaf_temperature_max
        FROM plants p JOIN forcing f ON p.datetime = f.date WHERE p.leaf_area > 0
        """))
    return first(result)
end

function _agripv_period_layout(metadata, n_plants)
    recipes = [entry["scene"] for entry in metadata["scenes"]]
    configurations = [get(recipe, "config", nothing) for recipe in recipes]
    all(x -> !isnothing(x), configurations) || return (; domain_area_m2=missing,
        actual_density_plants_m2=missing, target_density_plants_m2=missing)
    domains = [(Float64(config["panel_x_distance"]), Float64(config["panel_y_distance"])) for config in configurations]
    all(==(first(domains)), domains) || throw(ArgumentError("The saved horizontal domain changes over the comparison period."))
    domain_area_m2 = prod(first(domains))
    isfinite(domain_area_m2) && domain_area_m2 > 0 || throw(ArgumentError("Invalid saved horizontal domain area."))
    densities = [get(recipe, "plant_density", missing) for recipe in recipes]
    all(isequal(first(densities)), densities) || throw(ArgumentError("The saved target planting density changes over the period."))
    return (; domain_area_m2, actual_density_plants_m2=n_plants / domain_area_m2,
        target_density_plants_m2=first(densities))
end

function _agripv_period_PAR_totals!(con, metadata; input_dir)
    columns = propertynames(DataFrame(DBInterface.execute(con, "SELECT * FROM light LIMIT 0")))
    plant_columns = propertynames(DataFrame(DBInterface.execute(con, "SELECT * FROM plants LIMIT 0")))
    all(in(columns), (:datetime, :node_id, :plant_id, :plant_instance_id, :Ra_PAR_f, :area)) ||
        throw(ArgumentError("Period PAR energy requires light timestamps, node and stable plant identities, Ra_PAR_f and area."))
    _agripv_period_scalar(con, "SELECT count(*) AS n FROM light") == metadata["tables"]["light"]["rows"] ||
        throw(ArgumentError("Light output row count differs from its manifest."))
    days = sort(Date.(metadata["days"]))
    for role in ("plants", "light")
        file_days = Set(get(entry, "day", "") for entry in metadata["tables"][role]["files"])
        file_days == Set(string.(days)) ||
            throw(ArgumentError("The $role Parquet shard dates differ from the saved growth period."))
    end
    # COUNT(DISTINCT node_id) retains one key per organ/timestep. Restrict its
    # state to one daily scene, rather than retaining every seasonal organ.
    # Only one row per planting position/day remains after each validated scan.
    DBInterface.execute(con, "CREATE TEMP TABLE period_PAR_daily (plant_instance_id BIGINT, absorbed_PAR DOUBLE)")
    mismatch = :node_id in plant_columns ? " OR e.plant_node_id != p.node_id" : ""
    plant_identifiers = :node_id in plant_columns ? "datetime, plant_instance_id, node_id" : "datetime, plant_instance_id"
    for (index, day) in enumerate(days)
        # with_saved_outputs has already checked every source shard checksum.
        # Use the manifest index to avoid reopening all seasonal shards daily.
        light_scan = _agripv_parquet_scan(_agripv_saved_files(input_dir, metadata["tables"]["light"]; day, verify_hash=false))
        plant_scan = _agripv_parquet_scan(_agripv_saved_files(input_dir, metadata["tables"]["plants"]; day, verify_hash=false))
        start = "TIMESTAMP " * _agripv_sql_string(DateTime(day))
        stop = "TIMESTAMP " * _agripv_sql_string(DateTime(day + Day(1)))
        invalid_dates = _agripv_period_scalar(con, """
            SELECT count(*) FILTER (WHERE datetime IS NULL OR datetime < $start OR datetime >= $stop) AS n
            FROM $plant_scan
            """)
        invalid_dates == 0 || throw(ArgumentError("Plant Parquet shard dates differ from their declared day $day."))
        DBInterface.execute(con, "CREATE TEMP TABLE period_day_plants AS SELECT $plant_identifiers FROM $plant_scan")
        DBInterface.execute(con, """
            CREATE TEMP TABLE period_PAR_steps AS
            SELECT l.datetime, l.plant_instance_id,
                sum(l.Ra_PAR_f * l.area * f.duration) AS absorbed_PAR,
                count(*) AS n_organs, count(DISTINCT l.node_id) AS distinct_organs,
                count(DISTINCT l.plant_id) AS distinct_plant_nodes, min(l.plant_id) AS plant_node_id,
                count(*) FILTER (WHERE l.datetime IS NULL OR l.datetime < $start OR l.datetime >= $stop
                    OR l.node_id IS NULL OR l.node_id <= 0 OR l.plant_id <= 0 OR l.plant_instance_id <= 0
                    OR l.plant_instance_id IS NULL OR l.plant_id IS NULL OR f.date IS NULL
                    OR l.Ra_PAR_f IS NULL OR NOT isfinite(l.Ra_PAR_f) OR l.Ra_PAR_f < 0
                    OR l.area IS NULL OR NOT isfinite(l.area) OR l.area < 0) AS invalid_rows
            FROM $light_scan l LEFT JOIN forcing f ON l.datetime = f.date
            WHERE l.plant_id IS NOT NULL OR l.plant_instance_id IS NOT NULL
            GROUP BY l.datetime, l.plant_instance_id
            """)
        invalid = _agripv_period_scalar(con, """
            SELECT count(*) AS n FROM period_PAR_steps e
            LEFT JOIN period_day_plants p USING (datetime, plant_instance_id)
            WHERE e.invalid_rows > 0 OR e.n_organs != e.distinct_organs
                OR e.distinct_plant_nodes != 1 OR p.datetime IS NULL
                OR NOT isfinite(e.absorbed_PAR) $mismatch
            """)
        invalid == 0 || throw(ArgumentError("Plant PAR energy on $day has invalid, repeated or unmatched organ/timestep identities."))
        absent = _agripv_period_scalar(con, """
            SELECT count(*) AS n FROM period_day_plants p
            LEFT JOIN period_PAR_steps e USING (datetime, plant_instance_id)
            WHERE e.datetime IS NULL
            """)
        absent == 0 || throw(ArgumentError("Plant PAR energy is missing at saved plant timesteps on $day."))
        changed_organs = _agripv_period_scalar(con, """
            SELECT count(*) AS n FROM (
                SELECT plant_instance_id FROM period_PAR_steps GROUP BY plant_instance_id
                HAVING min(n_organs) != max(n_organs))
            """)
        changed_organs == 0 || throw(ArgumentError("The retained number of plant organs changes within saved daily scene $day."))
        DBInterface.execute(con, """
            INSERT INTO period_PAR_daily
            SELECT plant_instance_id, sum(absorbed_PAR) FROM period_PAR_steps GROUP BY plant_instance_id
            """)
        DBInterface.execute(con, "DROP TABLE period_PAR_steps")
        DBInterface.execute(con, "DROP TABLE period_day_plants")
        if index == 1 || index % 30 == 0 || index == length(days)
            @info "Validated all-organ PAR aggregation" config_id=metadata["config_id"] day days_completed=index n_days=length(days)
        end
    end
    DBInterface.execute(con, """
        CREATE TEMP TABLE period_PAR AS
        SELECT plant_instance_id, sum(absorbed_PAR) AS absorbed_PAR
        FROM period_PAR_daily GROUP BY plant_instance_id
        """)
end

"""
    summarize_period_outputs(; config_id, input_dir=..., verify_hash=true)

Sum retained extensive quantities over the full saved growth period and divide
each configuration total by its actual, stable planting population. Signed
`assimilation_step` is already integrated over area and time (μmol CO₂); sum it
once, ignoring the daily-reset `assimilation_cumulative`. `transpiration_step`
is already kg per step. Convert plant water rates to kg and all-organ absorbed
PAR powers to J with the saved duration of each individual timestep.

The extensive quantities are assimilation, PAR and transpiration; signed net
water exchange is included when its rate column was retained. Leaf temperature
is summarized separately as a green-leaf-area/time weighted mean and positive
area extrema. Its rows have no configuration sum or per-plant mean. Conductance
and leaf area are not summed. Source checksums, identities, populations, date/timestamp
coverage, finite values, duplicates and forcing durations are validated. Saved
forcing provenance is returned, including when it was reconstructed. No
geometry, meteorology or physics is recomputed.
"""
function summarize_period_outputs(; config_id,
    input_dir=joinpath(@__DIR__, "..", "2_outputs", "simulations", "yearly"), verify_hash=true)
    return with_saved_outputs(; config_id, tables=(:plants, :light, :forcing), input_dir, verify_hash) do con, metadata
        coverage = _validate_year_assimilation_outputs(con, metadata, config_id, input_dir; verify_hash)
        populations = unique(coverage.distinct_plants)
        length(populations) == 1 || throw(ArgumentError("Period per-plant means require a constant planting population."))
        n_plants = Int(only(populations))
        n_plants > 0 || throw(ArgumentError("The saved configuration contains no plants."))
        forcing = _agripv_validate_period_forcing!(con, coverage, metadata)
        optional = _agripv_period_plant_totals!(con, n_plants)
        temperatures = _agripv_period_temperatures(con)
        layout = _agripv_period_layout(metadata, n_plants)
        _agripv_period_PAR_totals!(con, metadata; input_dir)
        extra_columns = join([", p.$(_agripv_sql_identifier(name))" for name in optional])
        per_plant = DataFrame(DBInterface.execute(con, """
            SELECT p.plant_instance_id, p.net_assimilation, e.absorbed_PAR,
                p.transpiration $extra_columns
            FROM period_plants p JOIN period_PAR e USING (plant_instance_id)
            ORDER BY plant_instance_id
            """))
        :net_water_flux in propertynames(per_plant) && rename!(per_plant, :net_water_flux => :net_water_exchange)
        quantities = filter(q -> Symbol(q.quantity) in propertynames(per_plant), AGRIPV_PERIOD_QUANTITIES)
        days = sort(Date.(metadata["days"]))
        rows = map(quantities) do q
            values = per_plant[!, Symbol(q.quantity)]
            all(isfinite, values) || throw(ArgumentError("Nonfinite period total for $(q.quantity)."))
            total = sum(values)
            (; config_id=Int(config_id), period_start=first(days), period_end=last(days),
                n_days=length(days), n_steps=nrow(forcing), n_plants, layout...,
                quantity=q.quantity, unit=q.unit, total, mean_per_plant=total / n_plants,
                mean_unit=q.unit * " plant^-1", formula=q.formula, scope=q.scope,
                statistic_value=missing, aggregation="sum; mean per plant = total / n_plants",
                forcing_origin=get(metadata, "forcing_origin", "unspecified"))
        end
        temperature_rows = map(AGRIPV_PERIOD_TEMPERATURES) do q
            value = temperatures[Symbol(q.quantity)]
            ismissing(value) || isfinite(value) || throw(ArgumentError("Nonfinite period leaf temperature statistic."))
            (; config_id=Int(config_id), period_start=first(days), period_end=last(days),
                n_days=length(days), n_steps=nrow(forcing), n_plants, layout...,
                quantity=q.quantity, unit=q.unit, total=missing, mean_per_plant=missing,
                mean_unit=missing, formula=q.formula, scope=q.scope,
                statistic_value=value, aggregation=q.aggregation,
                forcing_origin=get(metadata, "forcing_origin", "unspecified"))
        end
        table = vcat(DataFrame(collect(rows)), DataFrame(collect(temperature_rows)))
        return (; table, per_plant, forcing, metadata)
    end
end

function _agripv_write_period_markdown(path, result; equal_populations)
    table = result.table
    row = first(table)
    open(path, "w") do io
        println(io, "# Configuration $(row.config_id): complete saved period\n")
        println(io, "Period: $(row.period_start) to $(row.period_end), $(row.n_days) days, $(row.n_steps) timesteps.\n")
        println(io, "Actual population: $(row.n_plants) plants. Each mean is the configuration total divided by this population.\n")
        !ismissing(row.domain_area_m2) && println(io, "Domain: $(row.domain_area_m2) m²; actual density: $(@sprintf("%.8g", row.actual_density_plants_m2)) plants m⁻²; target density: $(row.target_density_plants_m2) plants m⁻².\n")
        println(io, "| Quantity | Configuration total | Mean per plant | Temperature statistic | Unit |")
        println(io, "|---|---:|---:|---:|---|")
        labels = Dict(q.quantity => q.label for q in (AGRIPV_PERIOD_QUANTITIES..., AGRIPV_PERIOD_TEMPERATURES...))
        number(x) = ismissing(x) ? "—" : @sprintf("%.8g", x)
        for r in eachrow(table)
            println(io, "| $(labels[r.quantity]) | $(number(r.total)) | $(number(r.mean_per_plant)) | $(number(r.statistic_value)) | $(r.unit) |")
        end
        println(io, "\nAssimilation retains negative steps and sums `assimilation_step` once; the daily cumulative column is not used. Transpiration sums the saved kg per step once. Net water rates use each saved timestep duration. Per-plant column units are the displayed unit per plant.")
        println(io, "\nLeaf temperature is intensive: its mean is weighted by green leaf area × timestep duration across the whole configuration. Its extrema are the minimum/maximum positive-area green-leaf temperatures; no temperature is summed or divided by the plant count.")
        println(io, "\nPAR includes all plant organs, including green and senescent leaves and stems; soil and panels are excluded. Energy is `sum(Ra_PAR_f * area * duration_s)`.")
        println(io, "\nForcing origin: $(row.forcing_origin). $(get(result.metadata, "forcing_provenance", "No additional forcing provenance was retained."))")
        !equal_populations && println(io, "\nPlant populations differ between the compared configurations. The tables retain the actual populations; no population was assumed, replaced or rescaled.")
    end
end

"""Write one CSV and readable table per configuration, plus means comparison and provenance."""
function write_period_summary_tables(; config_ids=0:3,
    input_dir=joinpath(@__DIR__, "..", "2_outputs", "simulations", "yearly"),
    summary_dir=joinpath(@__DIR__, "..", "2_outputs", "period_summary"), verify_hash=true)
    config_ids = collect(config_ids)
    !isempty(config_ids) && allunique(config_ids) || throw(ArgumentError("Select unique configuration IDs."))
    results = Dict{Int,Any}()
    reference_forcing = nothing
    for config_id in config_ids
        @info "Summarizing complete saved period" config_id
        result = summarize_period_outputs(; config_id, input_dir, verify_hash)
        if isnothing(reference_forcing)
            reference_forcing = result.forcing
        else
            isequal(reference_forcing, result.forcing) || throw(ArgumentError("Compared configurations have different saved periods, timestamps or timestep durations."))
        end
        results[Int(config_id)] = result
    end
    populations = [first(results[Int(id)].table).n_plants for id in config_ids]
    equal_populations = all(==(first(populations)), populations)
    equal_populations || @warn "Configuration planting populations differ; using actual counts for per-plant means" config_ids populations
    mkpath(summary_dir)
    comparison = DataFrame()
    entries = Dict{String,Any}[]
    for config_id in config_ids
        result = results[Int(config_id)]
        table = result.table
        csv_path = joinpath(summary_dir, "config_$(config_id).csv")
        markdown_path = joinpath(summary_dir, "config_$(config_id).md")
        CSV.write(csv_path, table)
        _agripv_write_period_markdown(markdown_path, result; equal_populations)
        row = first(table)
        record = Dict{Symbol,Any}(:config_id => row.config_id, :period_start => row.period_start,
            :period_end => row.period_end, :n_days => row.n_days, :n_steps => row.n_steps,
            :n_plants => row.n_plants, :forcing_origin => row.forcing_origin,
            :domain_area_m2 => row.domain_area_m2,
            :actual_density_plants_m2 => row.actual_density_plants_m2,
            :target_density_plants_m2 => row.target_density_plants_m2)
        for r in eachrow(table)
            if ismissing(r.total)
                record[Symbol(r.quantity)] = r.statistic_value
            else
                record[Symbol(r.quantity * "_mean_per_plant")] = r.mean_per_plant
            end
        end
        push!(comparison, record; cols=:union)
        metadata_path = joinpath(input_dir, "scene_config_$(config_id).toml")
        push!(entries, Dict("config_id" => Int(config_id), "n_plants" => row.n_plants,
            "layout" => Dict(string(name) => (ismissing(value) ? "unspecified" : value)
                for (name, value) in pairs(_agripv_period_layout(result.metadata, row.n_plants))),
            "source_metadata" => relpath(metadata_path, summary_dir), "source_metadata_sha256" => _agripv_hash(metadata_path),
            "table" => basename(csv_path), "table_sha256" => _agripv_hash(csv_path),
            "readable_table" => basename(markdown_path), "readable_table_sha256" => _agripv_hash(markdown_path),
            "forcing_origin" => row.forcing_origin,
            "forcing_provenance" => get(result.metadata, "forcing_provenance", "unspecified")))
    end
    metadata_columns = [:config_id, :period_start, :period_end, :n_days, :n_steps, :n_plants,
        :domain_area_m2, :actual_density_plants_m2, :target_density_plants_m2, :forcing_origin]
    quantity_columns = [Symbol(q.quantity * "_mean_per_plant") for q in AGRIPV_PERIOD_QUANTITIES]
    temperature_columns = [Symbol(q.quantity) for q in AGRIPV_PERIOD_TEMPERATURES]
    select!(comparison, [metadata_columns; filter(in(propertynames(comparison)), quantity_columns); temperature_columns])
    CSV.write(joinpath(summary_dir, "comparison.csv"), comparison)
    provenance = Dict("summary_version" => 1, "period" => [string(first(reference_forcing.datetime)), string(last(reference_forcing.datetime))],
        "identity" => "plant_instance_id within configuration", "equal_plant_populations" => equal_populations,
        "mean_formula" => "configuration_total / actual_number_of_stable_planting_positions",
        "source_shard_checksums_verified" => verify_hash,
        "quantities" => [Dict("quantity" => q.quantity, "unit" => q.unit,
            "mean_unit" => q.unit * " plant^-1", "formula" => q.formula, "scope" => q.scope) for q in AGRIPV_PERIOD_QUANTITIES],
        "temperatures" => [Dict("quantity" => q.quantity, "unit" => q.unit,
            "formula" => q.formula, "scope" => q.scope, "aggregation" => q.aggregation) for q in AGRIPV_PERIOD_TEMPERATURES],
        "configs" => entries, "comparison_sha256" => _agripv_hash(joinpath(summary_dir, "comparison.csv")))
    open(joinpath(summary_dir, "provenance.toml"), "w") do io
        TOML.print(io, provenance)
    end
    return (; tables=Dict(id => result.table for (id, result) in results), comparison, equal_populations, summary_dir)
end
