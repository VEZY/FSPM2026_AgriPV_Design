using CSV, DataFrames, Dates, Statistics, TOML
using GLMakie, PlantGeom
isdefined(@__MODULE__, :load_day_outputs) || include("saved_simulation.jl")

"""Find the saved daily or growth-period recipe for one configuration and day."""
function _agripv_plot_day_metadata(config_id, day, input_dir)
    daily = joinpath(input_dir, "scene_config_$(config_id)_$(day).toml")
    filename = isfile(daily) ? daily : joinpath(input_dir, "scene_config_$(config_id).toml")
    isfile(filename) || throw(ArgumentError("Saved output recipe not found: $filename"))
    metadata = TOML.parsefile(filename)
    metadata["config_id"] == config_id || throw(ArgumentError("Saved configuration ID differs."))
    get(metadata, "format_version", nothing) in (1, 2) || throw(ArgumentError("Unsupported saved output format."))
    recipes = haskey(metadata, "scene") ? [metadata] : get(metadata, "scenes", [])
    matches = filter(entry -> entry["scene"]["day"] == string(day), recipes)
    length(matches) == 1 || throw(ArgumentError("Expected one saved scene recipe for $day, found $(length(matches))."))
    return metadata
end

"""Read a saved table for one day without rebuilding a scene or running a model."""
function load_plot_day_table(; config_id, day, table=:plants,
    input_dir=_agripv_yearly_output_dir(), variables=nothing, verify_hash=true)
    metadata = _agripv_plot_day_metadata(config_id, day, input_dir)
    info = get(metadata["tables"], string(table), nothing)
    isnothing(info) && throw(ArgumentError("The saved run did not retain $table."))
    get(info, "available", true) || throw(ArgumentError("Saved $table outputs are unavailable."))
    if haskey(info, "files")
        result = _agripv_read_parquet(input_dir, info; day, variables, verify_hash)
        expected_rows = sum(entry["rows"] for entry in info["files"]
            if get(entry, "day", "") == string(day); init=0)
        nrow(result) == expected_rows || throw(ArgumentError("Saved $table row/date coverage differs from its manifest."))
        return result
    end
    path = joinpath(input_dir, info["file"])
    isfile(path) || throw(ArgumentError("Saved table not found: $path"))
    verify_hash && _agripv_saved_file_sha256(path) != info["sha256"] &&
        throw(ArgumentError("Saved table checksum differs: $path"))
    result = _agripv_open_light(path) do io
        CSV.read(io, DataFrame)
    end
    result = filter(:datetime => stamp -> !ismissing(stamp) && Date(stamp) == Date(day), result)
    if !isnothing(variables)
        requested = variables isa Symbol ? [variables] : collect(variables)
        identities = intersect(collect(AGRIPV_OUTPUT_METADATA), propertynames(result))
        result = DataFrames.select(result, unique([identities; requested]))
    end
    return result
end

function _validate_plot_plant_series(table, variable)
    required = (:plant_id, :datetime, variable)
    all(name -> name in propertynames(table), required) ||
        throw(ArgumentError("Daily plant series require $required."))
    isempty(table) && throw(ArgumentError("No plant outputs for the selected day."))
    all(row -> row.plant_id isa Integer && !ismissing(row.datetime) &&
        row[variable] isa Real && isfinite(row[variable]), eachrow(table)) ||
        throw(ArgumentError("Plant identities, timestamps and $variable values must be present and finite."))
    nrow(unique(table[:, [:plant_id, :datetime]])) == nrow(table) ||
        throw(ArgumentError("Repeated plant identities at the same timestamp."))
    groups = groupby(table, :datetime)
    reference = Set(first(groups).plant_id)
    all(group -> Set(group.plant_id) == reference, groups) ||
        throw(ArgumentError("Plant coverage changes within the selected day."))
    return table
end

"""Read signed plant assimilation for one day across saved configurations."""
function saved_day_plant_series(; day=Date(2025, 7, 2), config_ids=0:3,
    variable=:assimilation_cumulative, input_dir=_agripv_yearly_output_dir(), verify_hash=true)
    tables = DataFrame[]
    timestamps = nothing
    for config_id in config_ids
        table = load_plot_day_table(; config_id, day, table=:plants, input_dir,
            variables=(variable,), verify_hash)
        _validate_plot_plant_series(table, variable)
        current = sort!(unique(table.datetime))
        if isnothing(timestamps)
            timestamps = current
        else
            current == timestamps || throw(ArgumentError("Configurations have different saved timestamps on $day."))
        end
        table.config_id = fill(config_id, nrow(table))
        push!(tables, table)
    end
    isempty(tables) && throw(ArgumentError("Select at least one configuration."))
    return sort!(vcat(tables...; cols=:union), [:config_id, :plant_id, :datetime])
end

function _plot_saved_day_durations(metadata, day, input_dir; verify_hash=true)
    info = get(metadata, "forcing", nothing)
    isnothing(info) && throw(ArgumentError(
        "Absorbed PAR energy requires saved forcing durations; this run did not retain them. Use quantity=:power to plot W per plant."))
    get(info, "available", true) || throw(ArgumentError("Saved forcing durations are unavailable."))
    if haskey(info, "files")
        paths = _agripv_saved_files(input_dir, info; day, verify_hash)
        result = _agripv_with_db() do con
            scan = _agripv_parquet_scan(paths)
            DataFrame(DBInterface.execute(con, """
                SELECT date AS datetime, duration AS duration_s FROM $scan
                WHERE CAST(date AS DATE) = DATE $(_agripv_sql_string(day)) ORDER BY date
                """))
        end
        expected_rows = sum(entry["rows"] for entry in info["files"]
            if get(entry, "day", "") == string(day); init=0)
        nrow(result) == expected_rows || throw(ArgumentError("Saved forcing row/date coverage differs from its manifest."))
        return result
    end
    path = joinpath(input_dir, info["file"])
    isfile(path) || throw(ArgumentError("Saved forcing not found: $path"))
    verify_hash && _agripv_saved_file_sha256(path) != info["sha256"] &&
        throw(ArgumentError("Saved forcing checksum differs: $path"))
    result = _agripv_open_light(path) do io
        CSV.read(io, DataFrame)
    end
    result = filter(:date => stamp -> !ismissing(stamp) && Date(stamp) == Date(day), result)
    return DataFrame(datetime=result.date, duration_s=result.duration)
end

function _attach_saved_step_energy!(radiation, forcing)
    required = (:datetime, :duration_s)
    all(name -> name in propertynames(forcing), required) ||
        throw(ArgumentError("Saved forcing requires timestamps and timestep durations."))
    all(row -> !ismissing(row.datetime) && row.duration_s isa Real &&
        isfinite(row.duration_s) && row.duration_s > 0, eachrow(forcing)) ||
        throw(ArgumentError("Saved forcing timestamps and positive finite durations are required."))
    length(unique(forcing.datetime)) == nrow(forcing) ||
        throw(ArgumentError("Repeated saved forcing timestamps."))
    Set(radiation.datetime) == Set(forcing.datetime) ||
        throw(ArgumentError("Saved radiation and forcing timestamps differ."))
    durations = Dict(row.datetime => Float64(row.duration_s) for row in eachrow(forcing))
    radiation.duration_s = [durations[stamp] for stamp in radiation.datetime]
    radiation.absorbed_PAR_J = radiation.absorbed_PAR_W .* radiation.duration_s
    all(isfinite, radiation.absorbed_PAR_J) || throw(ArgumentError("Nonfinite absorbed PAR energy."))
    return radiation
end

"""
Aggregate saved absorbed PAR over every geometric wheat organ.
`quantity=:power` returns W per plant. `quantity=:energy` also computes J per
plant per step using saved forcing durations matched exactly to timestamps.
"""
function saved_day_absorbed_par(; day=Date(2025, 7, 2), config_ids=0:3,
    input_dir=_agripv_yearly_output_dir(), verify_hash=true, quantity=:power)
    quantity in (:power, :energy) || throw(ArgumentError("Select quantity=:power or :energy."))
    tables = DataFrame[]
    timestamps = nothing
    for config_id in config_ids
        metadata = _agripv_plot_day_metadata(config_id, day, input_dir)
        info = get(metadata["tables"], "light", nothing)
        isnothing(info) && throw(ArgumentError("The saved run did not retain light outputs."))
        table = if haskey(info, "files")
            paths = _agripv_saved_files(input_dir, info; day, verify_hash)
            _agripv_with_db() do con
                scan = _agripv_parquet_scan(paths)
                expected_rows = sum(entry["rows"] for entry in info["files"]
                    if get(entry, "day", "") == string(day); init=0)
                coverage = DataFrame(DBInterface.execute(con,
                    "SELECT count(*) AS rows FROM $scan WHERE CAST(datetime AS DATE) = DATE $(_agripv_sql_string(day))"))
                only(coverage.rows) == expected_rows ||
                    throw(ArgumentError("Saved light row/date coverage differs from its manifest."))
                result = DataFrame(DBInterface.execute(con, """
                    SELECT plant_id, datetime, sum(Ra_PAR_f * area) AS absorbed_PAR_W,
                           count(*) AS organ_rows, count(DISTINCT node_id) AS distinct_organs,
                           count(*) FILTER (WHERE Ra_PAR_f IS NULL OR area IS NULL
                               OR NOT isfinite(Ra_PAR_f) OR NOT isfinite(area)) AS invalid_rows
                    FROM $scan
                    WHERE plant_id IS NOT NULL AND CAST(datetime AS DATE) = DATE $(_agripv_sql_string(day))
                    GROUP BY plant_id, datetime ORDER BY plant_id, datetime
                    """))
                all(row -> row.invalid_rows == 0 && row.organ_rows == row.distinct_organs,
                    eachrow(result)) || throw(ArgumentError("Invalid or repeated saved organ radiation rows."))
                DataFrames.select(result, :plant_id, :datetime, :absorbed_PAR_W)
            end
        else
            light = load_plot_day_table(; config_id, day, table=:light, input_dir,
                variables=(:Ra_PAR_f, :area), verify_hash)
            light = filter(:plant_id => id -> !ismissing(id), light)
            all(row -> row.Ra_PAR_f isa Real && isfinite(row.Ra_PAR_f) &&
                row.area isa Real && isfinite(row.area), eachrow(light)) ||
                throw(ArgumentError("Invalid saved organ radiation rows."))
            nrow(unique(light[:, [:node_id, :datetime]])) == nrow(light) ||
                throw(ArgumentError("Repeated saved organ radiation rows."))
            light.absorbed_PAR_W = light.Ra_PAR_f .* light.area
            combine(groupby(light, [:plant_id, :datetime]), :absorbed_PAR_W => sum => :absorbed_PAR_W)
        end
        _validate_plot_plant_series(table, :absorbed_PAR_W)
        if quantity == :energy
            forcing = _plot_saved_day_durations(metadata, day, input_dir; verify_hash)
            _attach_saved_step_energy!(table, forcing)
        end
        current = sort!(unique(table.datetime))
        if isnothing(timestamps)
            timestamps = current
        else
            current == timestamps || throw(ArgumentError("Configurations have different saved radiation timestamps on $day."))
        end
        table.config_id = fill(config_id, nrow(table))
        push!(tables, table)
    end
    isempty(tables) && throw(ArgumentError("Select at least one configuration."))
    return sort!(vcat(tables...), [:config_id, :plant_id, :datetime])
end

"""Compute each configuration's own arithmetic plant mean at each timestamp."""
daily_config_mean(table, variable) = sort!(combine(groupby(table, [:config_id, :datetime]),
    variable => mean => :value_mean), [:config_id, :datetime])

_agripv_plot_hours(stamps, day) = Dates.value.(DateTime.(stamps) .- DateTime(day)) ./ 3_600_000

"""Draw individual plant trajectories and their mean in one panel per configuration."""
function plot_daily_plant_panels(table; variable, day, ylabel, title)
    means = daily_config_mean(table, variable)
    configs = sort!(unique(table.config_id))
    ncols = min(2, length(configs))
    figure = Figure(size=(900, 700))
    Label(figure[0, 1:ncols], "$title — $day"; fontsize=20)
    for column in 1:ncols
        colsize!(figure.layout, column, Makie.Relative(1 / ncols))
    end
    for (index, config_id) in enumerate(configs)
        row, column = (index - 1) ÷ 2 + 1, (index - 1) % 2 + 1
        axis = Axis(figure[row, column]; title="Config $config_id", xlabel="Hour", ylabel, xticks=0:2:24)
        subset = filter(:config_id => ==(config_id), table)
        for plant in groupby(subset, :plant_id)
            lines!(axis, _agripv_plot_hours(plant.datetime, day), plant[!, variable]; color=(:black, 0.05))
        end
        average = filter(:config_id => ==(config_id), means)
        lines!(axis, _agripv_plot_hours(average.datetime, day), average.value_mean;
            color=:red, linewidth=3, label="Mean")
        autolimits!(axis)
        xlims!(axis, 0, 24)
    end
    return figure
end

function plot_daily_config_means(table; variable, day, ylabel, title)
    means = daily_config_mean(table, variable)
    figure = Figure(size=(900, 700))
    axis = Axis(figure[1, 1]; title="$title — $day", xlabel="Hour", ylabel, xticks=0:2:24)
    for config_id in sort!(unique(means.config_id))
        average = filter(:config_id => ==(config_id), means)
        lines!(axis, _agripv_plot_hours(average.datetime, day), average.value_mean;
            linewidth=2, label="Config $config_id")
    end
    autolimits!(axis)
    xlims!(axis, 0, 24)
    axislegend(axis; position=:lt)
    return figure
end

function _output_plot_range(table, variable, timestep)
    values = Float64[value for (step, value) in zip(table.timestep, table[!, variable])
        if step == timestep && value isa Real && isfinite(value)]
    isempty(values) && throw(ArgumentError("No finite $variable values at timestep $timestep."))
    lower, upper = extrema(values)
    if lower == upper
        iszero(lower) && return (0.0, 1.0)
        padding = abs(lower) * 0.05
        return (lower - padding, upper + padding)
    end
    return (lower, upper)
end

"""Attach one saved output snapshot by MTG node ID and color its geometry."""
function plot_output(mtg, table; variable=:A, timestep=13, label=string(variable),
    colorrange=nothing, colormap=:thermal, color_missing=:gray85, kwargs...)
    range = isnothing(colorrange) ? _output_plot_range(table, variable, timestep) : colorrange
    all(isfinite, range) && first(range) < last(range) ||
        throw(ArgumentError("colorrange must be finite and strictly increasing."))
    attach_outputs!(mtg, table; timestep, variables=(variable,))
    figure, axis, plot = plantviz(mtg; color=variable, color_mode=:node,
        colorrange=range, colormap, color_missing=Makie.to_color(color_missing), kwargs...)
    PlantGeom.colorbar(figure[1, 2], plot; label)
    return figure, axis, plot
end

"""Reconstruct only the saved geometry and load one output variable at one step."""
function plot_saved_output(; config_id, day, variable=:A, timestep=13,
    table=:leaves, output_dir=_agripv_yearly_output_dir(), kwargs...)
    saved = load_day_outputs(; config_id, day, output_dir, tables=(table,),
        timestep, variables=(variable,))
    return plot_output(saved.scene.mtg, getproperty(saved, table); variable, timestep, kwargs...)
end
