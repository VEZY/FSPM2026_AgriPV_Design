using GLMakie, PlantGeom, MultiScaleTreeGraph, TOML, Dates
isdefined(@__MODULE__, :write_integrated_plant_outputs) || include("attach_assimilation_to_scene.jl")
isdefined(@__MODULE__, :agripv_north_arrow!) || include("scene_orientation.jl")

# The small numeric CSVs and provenance.toml are derived from retained Parquet.
# Cached summaries are accepted only for the same saved metadata and CSV hashes.
function _ensure_cumulative_plant_summaries(input_dir, summary_dir)
    manifest = joinpath(summary_dir, "provenance.toml")
    current = false
    if isfile(manifest)
        provenance = TOML.parsefile(manifest)
        entries = get(provenance, "configs", [])
        current = get(provenance, "recipe_version", 0) == 2 &&
            get(provenance, "photons_per_J", nothing) == 4.57 &&
            length(entries) == 4 && Set(x["config_id"] for x in entries) == Set(0:3)
        for entry in entries
            metadata_path = joinpath(input_dir, "scene_config_$(entry["config_id"]).toml")
            csv_path = joinpath(summary_dir, entry["output_file"])
            current &= isfile(metadata_path) && isfile(csv_path) &&
                _agripv_saved_file_sha256(metadata_path) == entry["source_metadata_sha256"] &&
                _agripv_saved_file_sha256(csv_path) == entry["output_sha256"]
        end
    end
    if current
        for config_id in 0:3
            metadata = TOML.parsefile(joinpath(input_dir, "scene_config_$(config_id).toml"))
            for role in (:plants, :light, :forcing)
                info = role == :forcing ? metadata["forcing"] : metadata["tables"][string(role)]
                _agripv_saved_files(input_dir, info; verify_hash=true)
            end
        end
    end
    current || write_integrated_plant_outputs(; output_dir=input_dir, summary_dir)
    return nothing
end
function _cumulative_appfd_values(path; column="cumulative_appfd_mol_m2", allow_negative=false)
    lines = readlines(path)
    header = split(first(lines), ',')
    id_col, value_col = findfirst(==("plant_instance_id"), header), findfirst(==(column), header)
    isnothing(id_col) || isnothing(value_col) ?
        throw(ArgumentError("Required summary columns missing: $path")) : nothing
    values = Dict{Int,Float64}()
    for line in lines[2:end]
        row = split(line, ',')
        id, value = parse(Int, row[id_col]), parse(Float64, row[value_col])
        !haskey(values, id) && isfinite(value) && (allow_negative || value >= 0) ||
            throw(ArgumentError("Invalid or repeated planting ID in $path"))
        values[id] = value
    end
    return values
end

function _attach_cumulative_plant_values!(mtg, values)
    present = Set{Int}()
    function attach!(node, id=nothing)
        if symbol(node) == :Plant
            id = Int(node[:plantID])
            push!(present, id)
        end
        node[:cumulative_appfd] = isnothing(id) ? nothing : get(values, id, nothing)
        for child in children(node)
            attach!(child, id)
        end
    end
    # Validate every planting position before replacing the displayed values.
    MultiScaleTreeGraph.traverse!(mtg) do node
        symbol(node) == :Plant && push!(present, Int(node[:plantID]))
    end
    present == Set(keys(values)) || throw(ArgumentError("Summary planting IDs differ from saved geometry."))
    attach!(mtg)
    return mtg
end

function _cumulative_appfd_scene(root, config_id, day, values)
    saved = load_yearly_scene(; config_id, day, output_dir=root)
    metadata_path = joinpath(root, "scene_config_$(config_id).toml")
    metadata = TOML.parsefile(metadata_path)
    _attach_cumulative_plant_values!(saved.scene.mtg, values)
    return (; saved.scene, saved.config, days=metadata["days"],
        source_metadata_sha256=_agripv_saved_file_sha256(metadata_path))
end

"""
    plot_cumulative_appfd_3d(; quantity=:appfd, with_panels=false, ...)

Four 3D configurations with one shared scale. Select :appfd (mol photons/m²
green leaf area), :photons (mol photons/plant), or :assimilation (mol CO₂/plant).
The colors show the time integral of each plant's green-leaf-area-weighted
absorbed PPFD on one saved day's geometry. Run via Kaimon with `mt=true`.
"""
function plot_cumulative_appfd_3d(;
    input_dir=normpath(joinpath(@__DIR__, "..", "2_outputs", "simulations", "yearly")),
    summary_dir=normpath(joinpath(@__DIR__, "..", "2_outputs", "cumulative_appfd")),
    day=nothing, with_panels=false, prepared=nothing, quantity=:appfd)
    _ensure_cumulative_plant_summaries(input_dir, summary_dir)
    if isnothing(day)
        metadata = TOML.parsefile(joinpath(input_dir, "scene_config_0.toml"))
        day = maximum(Date.(metadata["days"]))
    end
    specs = Dict(
        :appfd => (; column="cumulative_appfd_mol_m2", title="Cumulative absorbed PPFD",
            label="Integrated leaf-mean aPPFD (mol photons m⁻²)", rounding=100.0, stem="cumulative_appfd", allow_negative=false),
        :photons => (; column="absorbed_photons_mol_plant", title="Total absorbed photons per plant",
            label="Absorbed photons (mol photons plant⁻¹)", rounding=0.5, stem="total_absorbed_photons", allow_negative=false),
        :assimilation => (; column="net_assimilation_mol_CO2_plant", title="Total net assimilation per plant",
            label="Net assimilation (mol CO₂ plant⁻¹)", rounding=0.02, stem="cumulative_net_assimilation", allow_negative=true),
    )
    haskey(specs, quantity) || throw(ArgumentError("Select :appfd, :photons or :assimilation."))
    spec = specs[quantity]
    values = [_cumulative_appfd_values(joinpath(summary_dir, "plants_config_$(c).csv");
        column=spec.column, allow_negative=spec.allow_negative) for c in 0:3]
    scenes = isnothing(prepared) ? [_cumulative_appfd_scene(input_dir, c, day, values[c+1]) for c in 0:3] : prepared
    length(scenes) == 4 || throw(ArgumentError("Expected four prepared configurations."))
    all(x -> x.days == scenes[1].days, scenes) || throw(ArgumentError("Configuration periods differ."))
    for (config_id, saved) in enumerate(scenes)
        metadata_path = joinpath(input_dir, "scene_config_$(config_id-1).toml")
        saved.source_metadata_sha256 == _agripv_saved_file_sha256(metadata_path) ||
            throw(ArgumentError("Prepared geometry belongs to a different saved configuration."))
        saved.scene.mtg[:agripv_scene_recipe]["day"] == string(day) ||
            throw(ArgumentError("Prepared geometry belongs to a different day."))
    end
    for (saved, plant_values) in zip(scenes, values)
        _attach_cumulative_plant_values!(saved.scene.mtg, plant_values)
    end
    extent = extrema(vcat([collect(Base.values(v)) for v in values]...))
    colorrange = (floor(first(extent) / spec.rounding) * spec.rounding,
        ceil(last(extent) / spec.rounding) * spec.rounding)
    first(colorrange) == last(colorrange) && (colorrange = (first(colorrange), last(colorrange) + spec.rounding))
    f = Figure(size=(1600, 1220), fontsize=20, backgroundcolor=:white)
    Label(f[0, 1:2], spec.title, fontsize=32, font=:bold)
    Label(f[1, 1:2], "$(first(scenes[1].days)) → $(last(scenes[1].days))  ·  $(length(scenes[1].days)) simulated days", fontsize=21, color=:gray35)
    for (i, saved) in enumerate(scenes)
        row, col = (i-1) ÷ 2 + 2, (i-1) % 2 + 1
        c = saved.config
        rotation = agripv_scene_rotation_deg(saved.scene)
        ax = Axis3(f[row, col]; aspect=:data,
            azimuth=agripv_local_camera_azimuth(rotation), elevation=0.24pi,
            perspectiveness=0, xlabel="local x (m)", ylabel="local y (m)", zlabel="z (m)",
            title="Config $(i-1)  ·  $(c.panel_x_distance) × $(c.panel_y_distance) m  ·  scene rotation $(Int(rotation))°",
            titlesize=22, titlegap=6, viewmode=:fit, protrusions=40,
            zticks=with_panels ? [0.0, 2.0, 4.0] : [0.0, 0.6],
            zgridvisible=false, xticklabelsize=17, yticklabelsize=17, zticklabelsize=17)
        if with_panels
            plantviz!(ax, saved.scene.mtg; color=:cumulative_appfd, color_mode=:node,
                colorrange, colormap=:viridis, color_missing=Makie.to_color(:gray85))
        else
            plantviz!(ax, saved.scene.mtg; color=:cumulative_appfd, color_mode=:node,
                colorrange, colormap=:viridis, color_missing=Makie.to_color(:gray85),
                filter_fun=n -> symbol(n) in (:Stem, :LeafSection))
            xmin, ymin, xmax, ymax = _agripv_orientation_domain(saved.scene)
            lines!(ax, Point3f[(xmin,ymin,0), (xmax,ymin,0),
                (xmax,ymax,0), (xmin,ymax,0), (xmin,ymin,0)];
                color=:gray65, linewidth=1.5)
        end
        agripv_north_arrow!(ax, saved.scene; fontsize=20)
        autolimits!(ax)
    end
    Colorbar(f[2:3, 3]; colormap=:viridis, limits=colorrange, width=24,
        label=spec.label)
    footer = quantity == :assimilation ? "Sum over all green leaves and timesteps · geometry: $(day)" :
        "Green-leaf absorption · one value per plant · geometry: $(day)"
    Label(f[4, 1:2], footer, fontsize=18, color=:gray35)
    Label(f[5, 1:2], (with_panels ? "Panels and ground shown in gray" : "Crop view · panels omitted to reveal spatial patterns") *
        " · N: geographic north · common geographic view", fontsize=17, color=:gray45)
    rowsize!(f.layout, 0, Makie.Fixed(42))
    rowsize!(f.layout, 1, Makie.Fixed(32))
    rowgap!(f.layout, 10)
    path = joinpath(summary_dir, "$(spec.stem)_3d_$(with_panels ? "with_panels" : "crop").png")
    save(path, f; px_per_unit=1.5)
    return (; figure=f, scenes, path, colorrange)
end
