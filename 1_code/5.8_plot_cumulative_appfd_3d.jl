using GLMakie, PlantGeom, GeometryBasics, MultiScaleTreeGraph, TOML, Dates, SHA
isdefined(@__MODULE__, :agripv_scene) || include("scene.jl")

# The small numeric CSVs and provenance.json are derived from the retained
# Parquet outputs. Their aggregation recipe is saved alongside the figures.
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

# Same world-space geometry/topology contract as saved_simulation.jl.
function _cumulative_scene_fingerprint(scene)
    io = IOBuffer()
    MultiScaleTreeGraph.traverse!(scene.mtg) do node
        ancestor = parent(node)
        print(io, node_id(node), '|', isnothing(ancestor) ? 0 : node_id(ancestor), '|',
            symbol(node), '|', MultiScaleTreeGraph.scale(node), '|',
            MultiScaleTreeGraph.index(node), '|', node[:state], '\n')
        mesh = PlantGeom.refmesh_to_mesh(node)
        if isnothing(mesh)
            write(io, Int64(0))
        else
            points, triangles = GeometryBasics.coordinates(mesh), GeometryBasics.faces(mesh)
            write(io, Int64(length(points)), Int64(length(triangles)))
            for point in points, value in point
                write(io, Float64(value))
            end
            for face in triangles, value in face
                write(io, Int64(value))
            end
        end
    end
    return bytes2hex(SHA.sha256(take!(io)))
end

function _cumulative_appfd_scene(root, config_id, day, values)
    metadata = TOML.parsefile(joinpath(root, "scene_config_$(config_id).toml"))
    entry = only(filter(x -> x["scene"]["day"] == string(day), metadata["scenes"]))
    recipe = entry["scene"]
    project = normpath(joinpath(@__DIR__, ".."))
    sources = Dict(name => normpath(joinpath(project, recipe[name * "_path"])) for name in ("obj", "mtg"))
    for (name, path) in sources
        bytes2hex(open(SHA.sha256, path)) == recipe[name * "_sha256"] ||
            throw(ArgumentError("Changed geometry source: $path"))
    end
    config = (; (Symbol(k) => v for (k, v) in recipe["config"])...)
    scene = agripv_scene(; c=config, day, obj_path=sources["obj"], mtg_path=sources["mtg"],
        plant_density=recipe["plant_density"], ground_res=recipe["ground_res"],
        ground_nx=recipe["ground_nx"], ground_ny=recipe["ground_ny"],
        plant_rotations=recipe["plant_rotations_rad"])
    _cumulative_scene_fingerprint(scene) == entry["scene_sha256"] ||
        throw(ArgumentError("Rebuilt geometry differs from the saved scene."))
    _attach_cumulative_plant_values!(scene.mtg, values)
    return (; scene, config, days=metadata["days"])
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
    day=Date(2025, 7, 2), with_panels=false, prepared=nothing, quantity=:appfd)
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
        ax = Axis3(f[row, col]; aspect=:data, azimuth=0.32pi, elevation=0.24pi,
            perspectiveness=0, xlabel="x (m)", ylabel="y (m)", zlabel="z (m)",
            title="Config $(i-1)  ·  $(c.panel_x_distance) × $(c.panel_y_distance) m  ·  $(Int(c.panel_orientation))°",
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
            lines!(ax, Point3f[(0,0,0), (c.panel_x_distance,0,0),
                (c.panel_x_distance,c.panel_y_distance,0), (0,c.panel_y_distance,0), (0,0,0)];
                color=:gray65, linewidth=1.5)
        end
    end
    Colorbar(f[2:3, 3]; colormap=:viridis, limits=colorrange, width=24,
        label=spec.label)
    footer = quantity == :assimilation ? "Sum over all green leaves and timesteps · geometry: $(day)" :
        "Green-leaf absorption · one value per plant · geometry: $(day)"
    Label(f[4, 1:2], footer, fontsize=18, color=:gray35)
    Label(f[5, 1:2], with_panels ? "Panels and ground shown in gray" : "Crop view · panels omitted to reveal spatial patterns", fontsize=17, color=:gray45)
    rowsize!(f.layout, 0, Makie.Fixed(42))
    rowsize!(f.layout, 1, Makie.Fixed(32))
    rowgap!(f.layout, 10)
    path = joinpath(summary_dir, "$(spec.stem)_3d_$(with_panels ? "with_panels" : "crop").png")
    save(path, f; px_per_unit=1.5)
    return (; figure=f, scenes, path, colorrange)
end
