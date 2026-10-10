using GLMakie, GeometryBasics, Colors, Dates, TOML
using PlantGeom, MultiScaleTreeGraph
isdefined(@__MODULE__, :load_yearly_scene) || include("saved_simulation.jl")

function _configuration_saved_day(config_ids, output_dir, day)
    days = nothing
    for config_id in config_ids
        metadata = TOML.parsefile(joinpath(output_dir, "scene_config_$(config_id).toml"))
        metadata["config_id"] == config_id || throw(ArgumentError("Saved configuration ID differs from the requested ID."))
        available = Set(Date(entry["scene"]["day"]) for entry in metadata["scenes"])
        days = isnothing(days) ? available : intersect(days, available)
    end
    isempty(days) && throw(ArgumentError("The configurations have no saved scene date in common."))
    selected = isnothing(day) ? maximum(days) : Date(day)
    selected in days || throw(ArgumentError("No saved scene for $selected in every requested configuration."))
    return selected
end

function _configuration_node_color(node)
    kind = MultiScaleTreeGraph.symbol(node)
    if kind == :LeafSection
        return node[:state] == "active" ? RGBf(0.2, 0.65, 0.08) : RGBf(0.72, 0.65, 0.38)
    elseif kind == :Stem
        return RGBf(0.1, 0.4, 0.0)
    elseif kind == :Panel
        return RGBf(0.015, 0.015, 0.015)
    elseif kind == :Cobblestone
        return RGBf(0.58, 0.49, 0.37)
    end
    return RGBf(0.5, 0.5, 0.5)
end

function _configuration_geometry(; config_id, day, output_dir)
    saved = load_yearly_scene(; config_id, day, output_dir)
    scene = saved.scene
    domain = scene.scene_xy_bounds
    isnothing(domain) && throw(ArgumentError("The saved scene has no periodic domain."))
    xmin, ymin, xmax, ymax = domain
    all(isfinite, domain) && xmin < xmax && ymin < ymax ||
        throw(ArgumentError("The saved periodic domain must have finite, positive dimensions."))

    node_colors = Dict{Int,RGBf}()
    ghost_node_colors = Dict{Int,RGBAf}()
    traverse!(scene.mtg) do node
        color = _configuration_node_color(node)
        node_colors[node_id(node)] = color
        # Many wheat surfaces overlap in projection. Fade and desaturate these
        # more strongly so the repeated canopy stays visibly subordinate.
        vegetation = MultiScaleTreeGraph.symbol(node) in (:LeafSection, :Stem)
        ghost_node_colors[node_id(node)] = vegetation ?
            RGBAf(0.65 + 0.35 * color.r, 0.65 + 0.35 * color.g, 0.65 + 0.35 * color.b, 0.1) :
            RGBAf(color.r, color.g, color.b, 1)
    end
    points = Point3f.(GeometryBasics.coordinates(scene.merged_mesh))
    triangles = GeometryBasics.faces(scene.merged_mesh)
    length(triangles) == length(scene.face2node) || throw(ArgumentError("Invalid face-to-node geometry mapping."))
    colors = fill(RGBf(0.5, 0.5, 0.5), length(points))
    ghost_colors = fill(RGBAf(0.5, 0.5, 0.5, 1), length(points))
    for (triangle, id) in zip(triangles, scene.face2node)
        color = node_colors[id]
        ghost_color = ghost_node_colors[id]
        for vertex in triangle
            colors[vertex] = color
            ghost_colors[vertex] = ghost_color
        end
    end
    # Build normals once and share this geometry between all translated plots.
    mesh = GeometryBasics.normal_mesh(GeometryBasics.Mesh(points, triangles))
    bounds = ntuple(i -> extrema(point[i] for point in points), 3)
    return (; config_id, day, config=saved.config, domain, mesh, colors, ghost_colors, bounds)
end

function _configuration_offsets(prepared; repeats=(2, 2))
    nx, ny = repeats
    nx isa Integer && ny isa Integer && nx > 0 && ny > 0 ||
        throw(ArgumentError("repeats must contain two positive integer tile counts."))
    azimuth = deg2rad(45 + prepared.config.panel_orientation)
    # Put the opaque simulation cell in the foreground for either orientation.
    xdirection = cos(azimuth) >= 0 ? -1 : 1
    ydirection = sin(azimuth) >= 0 ? -1 : 1
    xmin, ymin, xmax, ymax = prepared.domain
    return [(xdirection * i * (xmax - xmin), ydirection * j * (ymax - ymin))
        for j in 0:(ny - 1) for i in 0:(nx - 1)]
end

function _configuration_box!(ax, prepared; fontsize=20)
    xmin, ymin, xmax, ymax = prepared.domain
    zmin, zmax = prepared.bounds[3]
    corners = [Point3f(x, y, z) for z in (zmin, zmax) for y in (ymin, ymax) for x in (xmin, xmax)]
    edges = ((1, 2), (1, 3), (2, 4), (3, 4), (5, 6), (5, 7), (6, 8), (7, 8),
        (1, 5), (2, 6), (3, 7), (4, 8))
    linesegments!(ax, [corners[i] for edge in edges for i in edge];
        color=RGBf(0.15, 0.15, 0.15), linewidth=1.2)

    azimuth = deg2rad(45 + prepared.config.panel_orientation)
    xfront = cos(azimuth) >= 0 ? xmax : xmin
    yfront = sin(azimuth) >= 0 ? ymax : ymin
    xsign = cos(azimuth) >= 0 ? 1 : -1
    ysign = sin(azimuth) >= 0 ? 1 : -1
    dx, dy = xmax - xmin, ymax - ymin
    label_gap = 0.10 * max(dx, dy)
    text!(ax, Point3f((xmin + xmax) / 2, yfront + ysign * label_gap, zmin);
        text="x (m)", fontsize, align=(:center, :center))
    text!(ax, Point3f(xfront + xsign * label_gap, (ymin + ymax) / 2, zmin);
        text="y (m)", fontsize, align=(:center, :center))
    # Use the leftmost box edge for z labels, away from the foreground canopy.
    horizontal = (-sin(azimuth), cos(azimuth))
    zcorner = (horizontal[1] >= 0 ? xmin : xmax, horizontal[2] >= 0 ? ymin : ymax)
    text!(ax, Point3f(zcorner[1] - horizontal[1] * label_gap,
        zcorner[2] - horizontal[2] * label_gap, (zmin + zmax) / 2);
        text="z (m)", fontsize, rotation=pi / 2, align=(:center, :center))
    for z in 0:2:floor(Int, zmax)
        text!(ax, Point3f(zcorner[1] - horizontal[1] * label_gap * 0.35,
            zcorner[2] - horizontal[2] * label_gap * 0.35, z);
            text=string(z), fontsize=fontsize - 3, align=(:center, :center))
    end
    return nothing
end

function _configuration_axis!(position, prepared; repeats=(2, 2), repeat_alpha=0.18, fontsize=20)
    0 < repeat_alpha < 1 || throw(ArgumentError("repeat_alpha must lie strictly between zero and one."))
    offsets = _configuration_offsets(prepared; repeats)
    xmin, ymin, xmax, ymax = prepared.domain
    ax = Axis3(position; aspect=:data, perspectiveness=0,
        azimuth=deg2rad(45 + prepared.config.panel_orientation), elevation=deg2rad(30),
        title="Config $(prepared.config_id) · $(prepared.config.panel_orientation |> Int)°\n$(xmax - xmin) × $(ymax - ymin) m simulated cell",
        titlefont=:bold, titlesize=fontsize + 2, protrusions=(15, 15, 20, 85),
        xspinesvisible=false, yspinesvisible=false, zspinesvisible=false,
        xypanelvisible=false, xzpanelvisible=false, yzpanelvisible=false)
    hidedecorations!(ax)
    for (dx, dy) in offsets
        original = dx == 0 && dy == 0
        p = mesh!(ax, prepared.mesh; color=original ? prepared.colors : prepared.ghost_colors,
            alpha=original ? 1.0 : repeat_alpha, transparency=!original)
        translate!(p, dx, dy, 0)
    end
    _configuration_box!(ax, prepared; fontsize)
    xoffsets, yoffsets = first.(offsets), last.(offsets)
    xbounds, ybounds, zbounds = prepared.bounds
    xlims = (xbounds[1] + minimum(xoffsets), xbounds[2] + maximum(xoffsets))
    ylims = (ybounds[1] + minimum(yoffsets), ybounds[2] + maximum(yoffsets))
    margin = max(0.06 * max(xlims[2] - xlims[1], ylims[2] - ylims[1]),
        0.13 * max(xmax - xmin, ymax - ymin))
    limits!(ax, xlims[1] - margin, xlims[2] + margin,
        ylims[1] - margin, ylims[2] + margin, zbounds[1] - 0.05, zbounds[2] + 0.15)
    return ax
end

function _configuration_footer(figure, row, day; repeated, columns=1)
    meaning = repeated ? "Opaque: simulated cell   ·   Faded: periodic repetitions" : "Outlined: simulated cell"
    Label(figure[row, 1:columns], "$meaning   ·   Geometry: $day";
        fontsize=19, color=RGBf(0.35, 0.35, 0.35), padding=(0, 0, 8, 8), tellwidth=false)
end

"""
    plot_configurations(; config_ids=0:3, day=nothing, repeats=(2,2), repeat_alpha=0.18, ...)

Export each saved configuration as a single cell and with translucent periodic
copies, plus one combined repeated-design figure. The opaque cell and its box
are the simulated domain; copies share the original mesh and use exact saved
domain periods. Preserve the orientation convention of the historical figure.
Default to the last saved scene date common to all requested configurations.
Run through Kaimon with `mt=true`; no simulation is executed.
"""
function plot_configurations(; config_ids=0:3, day=nothing, repeats=(2, 2), repeat_alpha=0.18,
    input_dir=_agripv_yearly_output_dir(), output_dir=joinpath(_agripv_project_root(), "2_outputs"))
    config_ids = collect(config_ids)
    !isempty(config_ids) && length(unique(config_ids)) == length(config_ids) ||
        throw(ArgumentError("Provide a nonempty set of unique configuration IDs."))
    day = _configuration_saved_day(config_ids, input_dir, day)
    mkpath(output_dir)
    geometries = Any[]
    paths = String[]
    0 < repeat_alpha < 1 || throw(ArgumentError("repeat_alpha must lie strictly between zero and one."))
    for config_id in config_ids
        @info "Rendering saved configuration geometry" config_id day
        prepared = _configuration_geometry(; config_id, day, output_dir=input_dir)
        push!(geometries, prepared)
        for repeated in (false, true)
            figure = Figure(size=(1100, 1000), fontsize=22, backgroundcolor=:white)
            _configuration_axis!(figure[1, 1], prepared;
                repeats=repeated ? repeats : (1, 1), repeat_alpha, fontsize=22)
            _configuration_footer(figure, 2, day; repeated)
            suffix = repeated ? "_repeated" : ""
            path = joinpath(output_dir, "config_$(config_id)$(suffix).png")
            save(path, figure; px_per_unit=2)
            push!(paths, path)
            GLMakie.closeall()
            GC.gc()
        end
    end
    figure = Figure(size=(1600, 1500), fontsize=22, backgroundcolor=:white)
    columns = min(2, length(geometries))
    Label(figure[0, 1:columns], "Periodic AgriPV configurations"; fontsize=30, font=:bold, tellwidth=false)
    for (i, prepared) in enumerate(geometries)
        row, col = divrem(i - 1, columns)
        _configuration_axis!(figure[row + 1, col + 1], prepared; repeats, repeat_alpha, fontsize=21)
    end
    _configuration_footer(figure, cld(length(geometries), columns) + 1, day; repeated=true, columns)
    path = joinpath(output_dir, "configurations_repeated.png")
    save(path, figure; px_per_unit=2)
    push!(paths, path)
    GLMakie.closeall()
    return (; day, repeats, repeat_alpha, paths)
end
