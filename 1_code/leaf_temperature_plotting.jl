using CSV, DataFrames, Dates, Statistics, TOML
using GLMakie, Colors, MultiScaleTreeGraph
isdefined(@__MODULE__, :_configuration_geometry) || include("configuration_plotting.jl")

"""Daily green LAI from retained exchanging leaf area, divided by saved ground area."""
function saved_green_lai(; config_ids=0:3, input_dir=_agripv_yearly_output_dir(), verify_hash=true)
    summaries = DataFrame[]
    for config_id in config_ids
        summary = with_saved_outputs(; config_id, tables=(:plants,), input_dir, verify_hash) do con, metadata
            areas = Dict(Date(entry["scene"]["day"]) =>
                entry["scene"]["config"]["panel_x_distance"] * entry["scene"]["config"]["panel_y_distance"]
                for entry in metadata["scenes"])
            all(x -> isfinite(x) && x > 0, values(areas)) ||
                throw(ArgumentError("Invalid saved ground areas."))
            hourly = DataFrame(DBInterface.execute(con, """
                SELECT datetime, sum(leaf_area) AS leaf_area, count(*) AS rows,
                    count(DISTINCT plant_id) AS plant_count,
                    count(*) FILTER (WHERE leaf_area IS NULL OR NOT isfinite(leaf_area)
                        OR leaf_area < 0 OR plant_id IS NULL) AS invalid
                FROM plants GROUP BY datetime ORDER BY datetime
                """))
            isempty(hourly) && throw(ArgumentError("No retained plant outputs."))
            sum(hourly.rows) == metadata["tables"]["plants"]["rows"] ||
                throw(ArgumentError("Plant row coverage differs from its manifest."))
            all(row -> row.invalid == 0 && row.rows == row.plant_count, eachrow(hourly)) ||
                throw(ArgumentError("Invalid or duplicated plant areas at a timestamp."))
            hourly.day = Date.(hourly.datetime)
            Set(hourly.day) == Set(keys(areas)) ||
                throw(ArgumentError("LAI date coverage differs from the saved scenes."))
            daily = combine(groupby(hourly, :day), :leaf_area => minimum => :min_area,
                :leaf_area => maximum => :leaf_area, :plant_count => minimum => :min_plants,
                :plant_count => maximum => :plant_count)
            all(row -> isapprox(row.min_area, row.leaf_area; rtol=1e-9, atol=1e-9) &&
                row.min_plants == row.plant_count, eachrow(daily)) ||
                throw(ArgumentError("Green leaf area or plant coverage changes within a saved geometry day."))
            daily.ground_area = [areas[day] for day in daily.day]
            daily.lai = daily.leaf_area ./ daily.ground_area
            daily.config_id = fill(config_id, nrow(daily))
            DataFrames.select(daily, :config_id, :day, :plant_count, :leaf_area, :ground_area, :lai)
        end
        push!(summaries, summary)
    end
    isempty(summaries) && throw(ArgumentError("Select at least one configuration."))
    return sort!(vcat(summaries...), [:config_id, :day])
end

"""Choose the earliest day attaining each configuration's maximum green LAI."""
function _common_peak_lai_day(lai)
    shared = nothing
    for config in groupby(lai, :config_id)
        peak = maximum(config.lai)
        days = Set(config.day[isapprox.(config.lai, peak; rtol=1e-9, atol=1e-9)])
        shared = isnothing(shared) ? days : intersect(shared, days)
    end
    isnothing(shared) || isempty(shared) ?
        throw(ArgumentError("Maximum green-LAI dates differ between configurations; select an explicit comparison day.")) :
        minimum(shared)
end

"""Find a common peak incident-PAR instant; retain the forcing's original provenance."""
function _temperature_peak_forcing(config_ids, day, input_dir; verify_hash=true)
    reference = nothing
    provenance = Dict{String,Any}[]
    for config_id in config_ids
        forcing, origin, source = with_saved_outputs(; config_id, tables=(:forcing,),
            day, input_dir, verify_hash) do con, metadata
            table = DataFrame(DBInterface.execute(con,
                "SELECT date, duration, Ri_PAR_f FROM forcing ORDER BY date"))
            (table, get(metadata, "forcing_origin", "saved"),
                get(metadata, "forcing_provenance", "saved simulation forcing"))
        end
        isempty(forcing) && throw(ArgumentError("No forcing for $day."))
        length(unique(forcing.date)) == nrow(forcing) && all(row ->
            Date(row.date) == day && isfinite(row.duration) && row.duration > 0 &&
            isfinite(row.Ri_PAR_f) && row.Ri_PAR_f >= 0, eachrow(forcing)) ||
            throw(ArgumentError("Invalid incident-PAR forcing."))
        if isnothing(reference)
            reference = forcing
        else
            isequal(reference, forcing) ||
                throw(ArgumentError("Configurations have different saved forcing on $day."))
        end
        push!(provenance, Dict("config_id" => config_id, "origin" => origin, "source" => source))
    end
    step = argmax(reference.Ri_PAR_f) # Earliest instant if the maximum is tied.
    reference.Ri_PAR_f[step] > 0 || throw(ArgumentError("The selected day has no positive incident PAR."))
    return (; datetime=reference.date[step], timestep=step,
        incoming_PAR_W_m2=reference.Ri_PAR_f[step], provenance)
end

function _temperature_color(value, palette, colorrange)
    position = 1 + clamp((value - first(colorrange)) / (last(colorrange) - first(colorrange)), 0, 1) * (length(palette) - 1)
    lower = floor(Int, position)
    upper = min(lower + 1, length(palette))
    weight = position - lower
    a, b = RGBf(palette[lower]), RGBf(palette[upper])
    return RGBf((1 - weight) * a.r + weight * b.r,
        (1 - weight) * a.g + weight * b.g, (1 - weight) * a.b + weight * b.b)
end

"""
    plot_leaf_temperature_3d(; config_ids=0:3, day=nothing, repeats=(1,1), ...)

Read retained leaf-section temperatures at peak incoming PAR on the earliest
common maximum-green-LAI day. Green LAI is actual exchanging leaf area divided
by each saved domain's ground area, not the STICS growth target `laimax`.
Rebuild the matching saved meshes and validate their fingerprints/node IDs.
All four views share physical scale, geographic orientation, a North arrow,
and one temperature color range/bar. Mesh shading is disabled so surface
orientation cannot alter the temperature colors. Other organs remain neutral.
`day` can select another saved day; `repeats` adds translucent periodic context.
Write a combined PNG, four individual PNGs, daily LAI CSV, selected-temperature
summary CSV and TOML provenance. Timestamps are used as saved, without a time
zone conversion. Execute through Kaimon with `mt=true`; no model is run.
"""
function plot_leaf_temperature_3d(; config_ids=0:3, day=nothing, repeats=(1, 1),
    repeat_alpha=0.18, colormap=:thermal, colorrange=nothing,
    input_dir=_agripv_yearly_output_dir(), output_dir=joinpath(_agripv_project_root(), "2_outputs"))
    config_ids = collect(config_ids)
    !isempty(config_ids) && length(unique(config_ids)) == length(config_ids) ||
        throw(ArgumentError("Provide a nonempty set of unique configurations."))
    automatic_day = isnothing(day)
    lai = saved_green_lai(; config_ids, input_dir)
    day = isnothing(day) ? _common_peak_lai_day(lai) : Date(day)
    forcing = _temperature_peak_forcing(config_ids, day, input_dir)
    snapshots = DataFrame[]
    # Determine the shared range before building the much larger scene meshes.
    for config_id in config_ids
        metadata = TOML.parsefile(joinpath(input_dir, "scene_config_$(config_id).toml"))
        snapshot = _agripv_read_parquet(input_dir, metadata["tables"]["leaves"];
            day, timestep=forcing.timestep, variables=(:Tₗ, :area))
        isempty(snapshot) && throw(ArgumentError("No leaf temperature snapshot for config $config_id."))
        all(==(forcing.datetime), snapshot.datetime) ||
            throw(ArgumentError("Leaf timestamps differ from the selected forcing instant."))
        all(x -> x isa Real && isfinite(x) && x >= 0, snapshot.area) ||
            throw(ArgumentError("Invalid retained leaf area."))
        snapshot = filter(:area => >(0), snapshot)
        isempty(snapshot) && throw(ArgumentError("No positive-area leaves in config $config_id."))
        all(x -> x isa Real && isfinite(x), snapshot.Tₗ) ||
            throw(ArgumentError("Missing or nonfinite positive-area leaf temperatures."))
        length(unique(snapshot.node_id)) == nrow(snapshot) ||
            throw(ArgumentError("Duplicate leaf node identities."))
        push!(snapshots, snapshot)
    end
    all_temperatures = vcat((table.Tₗ for table in snapshots)...)
    if isnothing(colorrange)
        low, high = extrema(all_temperatures)
        # Round outward to half-degree ticks without clipping any retained value.
        colorrange = (floor(low * 2) / 2, ceil(high * 2) / 2)
        first(colorrange) == last(colorrange) &&
            (colorrange = (first(colorrange) - 0.5, last(colorrange) + 0.5))
    end
    all(isfinite, colorrange) && first(colorrange) < last(colorrange) ||
        throw(ArgumentError("Temperature colorrange must be finite and strictly increasing."))
    palette = GLMakie.Makie.to_colormap(colormap)
    geometries = Any[]
    statistics = DataFrame()
    for (config_id, table) in zip(config_ids, snapshots)
        @info "Coloring retained leaf temperatures" config_id day datetime=forcing.datetime
        saved = load_day_outputs(; config_id, day, output_dir=input_dir, tables=())
        _validate_saved_output_table!(table, saved.scene)
        colors = Dict{Int,RGBf}()
        traverse!(saved.scene.mtg) do node
            colors[node_id(node)] = MultiScaleTreeGraph.symbol(node) == :Panel ? RGBf(0.015, 0.015, 0.015) : RGBf(0.8, 0.8, 0.8)
        end
        for row in eachrow(table)
            colors[row.node_id] = _temperature_color(row.Tₗ, palette, colorrange)
        end
        push!(geometries, _configuration_geometry(; config_id, day, output_dir=input_dir,
            saved, color_by_node=colors))
        lai_row = only(eachrow(filter(row -> row.config_id == config_id && row.day == day, lai)))
        isapprox(sum(table.area), lai_row.leaf_area; rtol=1e-9, atol=1e-8) ||
            throw(ArgumentError("Leaf-section area differs from retained plant area."))
        push!(statistics, (; config_id, day, datetime=forcing.datetime, timestep=forcing.timestep,
            lai=lai_row.lai, leaf_sections=nrow(table), leaf_area_m2=sum(table.area),
            temperature_min_C=minimum(table.Tₗ), temperature_max_C=maximum(table.Tₗ),
            temperature_area_mean_C=sum(table.Tₗ .* table.area) / sum(table.area)))
        saved = nothing
        GC.gc()
    end
    mkpath(output_dir)
    stamp = Dates.format(forcing.datetime, "yyyymmdd_HHMM")
    stem = "leaf_temperature_3d_$(stamp)"
    files = String[]
    columns = min(2, length(config_ids))
    rows = cld(length(config_ids), columns)
    figure = Figure(size=(1800, 1500), fontsize=22, backgroundcolor=:white)
    Label(figure[0, 1:columns], "Leaf temperature · $day · $(Dates.format(forcing.datetime, "HH:MM"))";
        fontsize=30, font=:bold, tellwidth=false)
    axes = Axis3[]
    for (i, prepared) in enumerate(geometries)
        row, col = divrem(i - 1, columns)
        push!(axes, _configuration_axis!(figure[row + 1, col + 1], prepared;
            repeats, repeat_alpha, fontsize=21, shading=NoShading))
    end
    spans = _configuration_match_scales!(axes)
    Colorbar(figure[1:rows, columns + 1]; colormap, colorrange,
        label="Leaf temperature (°C)", labelsize=24, ticklabelsize=21, width=28)
    forcing_note = any(p -> p["origin"] == "reconstructed", forcing.provenance) ?
        "Peak incident PAR selected from reconstructed forcing" : "Peak incident PAR"
    day_note = automatic_day ? "Maximum green-LAI day" : "Selected day"
    Label(figure[rows + 1, 1:columns + 1],
        "$day_note · $forcing_note\nSame scale in all panels · N: geographic north · Grey: other organs";
        fontsize=18, color=:gray35, tellwidth=false)
    combined = joinpath(output_dir, "$stem.png")
    save(combined, figure; px_per_unit=2)
    push!(files, combined)
    GLMakie.closeall()
    empty!(axes)
    figure = nothing
    GC.gc()
    for prepared in geometries
        figure = Figure(size=(1200, 1000), fontsize=22, backgroundcolor=:white)
        ax = _configuration_axis!(figure[1, 1], prepared;
            repeats, repeat_alpha, fontsize=22, shading=NoShading)
        _configuration_match_scales!([ax]; spans)
        Colorbar(figure[1, 2]; colormap, colorrange, label="Leaf temperature (°C)")
        Label(figure[0, 1:2], "$day · $(Dates.format(forcing.datetime, "HH:MM"))";
            fontsize=26, tellwidth=false)
        Label(figure[2, 1:2], forcing_note; fontsize=17, color=:gray35, tellwidth=false)
        path = joinpath(output_dir, "$(stem)_config_$(prepared.config_id).png")
        save(path, figure; px_per_unit=2)
        push!(files, path)
        GLMakie.closeall()
        GC.gc()
    end
    CSV.write(joinpath(output_dir, "$(stem)_summary.csv"), statistics)
    CSV.write(joinpath(output_dir, "$(stem)_daily_lai.csv"), lai)
    open(joinpath(output_dir, "$(stem).toml"), "w") do io
        TOML.print(io, Dict("day" => string(day), "datetime" => string(forcing.datetime),
            "timestep" => forcing.timestep, "config_ids" => config_ids, "repeats" => collect(repeats),
            "colorrange_C" => collect(colorrange), "incoming_PAR_W_m2" => forcing.incoming_PAR_W_m2,
            "date_selection" => automatic_day ? "earliest common maximum green LAI" : "caller-selected saved day",
            "lai_definition" => "sum of retained positive-area active leaf sections / saved ground area",
            "time_selection" => "earliest maximum Ri_PAR_f; timestamps as saved, without timezone conversion",
            "temperature_source" => "retained LeafSection Tₗ (degC); no physics rerun",
            "mesh_shading" => "NoShading; temperature colors independent of surface orientation",
            "input_dir" => abspath(input_dir), "forcing" => forcing.provenance))
    end
    return (; day, datetime=forcing.datetime, timestep=forcing.timestep,
        colorrange, forcing, statistics, spans, files)
end
