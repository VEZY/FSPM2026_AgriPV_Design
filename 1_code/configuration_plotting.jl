using GLMakie, GeometryBasics, Colors, Dates, TOML
using PlantGeom, MultiScaleTreeGraph
isdefined(@__MODULE__, :load_yearly_scene) || include("saved_simulation.jl")
isdefined(@__MODULE__, :agripv_cardinal_arrow!) || include("scene_orientation.jl")

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

function _configuration_geometry(; config_id, day, output_dir, saved=nothing, color_by_node=nothing)
    saved = isnothing(saved) ? load_yearly_scene(; config_id, day, output_dir) : saved
    scene = saved.scene
    domain = scene.scene_xy_bounds
    isnothing(domain) && throw(ArgumentError("The saved scene has no periodic domain."))
    xmin, ymin, xmax, ymax = domain
    all(isfinite, domain) && xmin < xmax && ymin < ymax ||
        throw(ArgumentError("The saved periodic domain must have finite, positive dimensions."))

    node_colors = Dict{Int,RGBf}()
    ghost_node_colors = Dict{Int,RGBAf}()
    traverse!(scene.mtg) do node
        color = isnothing(color_by_node) ? _configuration_node_color(node) :
            get(color_by_node, node_id(node), _configuration_node_color(node))
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
    rotation = agripv_scene_rotation_deg(scene)
    # The overview needs the mesh, domain and orientation only. Release the
    # reconstructed MTG instead of retaining four complete scenes in memory.
    return (; config_id, day, config=saved.config, rotation, domain, mesh, colors, ghost_colors, bounds)
end

function _configuration_camera(view)
    view == :threequarter && return (; geographic_azimuth_deg=225.0, elevation=deg2rad(30))
    # Avoid the singular lookat basis at the exact zenith, with negligible
    # height parallax (<1 cm for a 5 m panel). South is strictly vertical.
    view == :top && return (; geographic_azimuth_deg=270.0, elevation=deg2rad(89.9))
    throw(ArgumentError("Select configuration view :threequarter or :top."))
end

function _configuration_offsets(prepared; repeats=(2, 2), geographic_azimuth_deg=225.0)
    nx, ny = repeats
    nx isa Integer && ny isa Integer && nx > 0 && ny > 0 ||
        throw(ArgumentError("repeats must contain two positive integer tile counts."))
    azimuth = agripv_local_camera_azimuth(prepared.rotation; geographic_azimuth_deg)
    # Put copies behind the opaque cell for the selected geographic view.
    # Changing the camera by 180° reverses these offsets, keeping copies above.
    # At cardinal bearings, tiny floating-point signs must not choose which
    # side receives the copies. The tie puts them on the same side each time.
    xdirection = cos(azimuth) >= -1e-12 ? -1 : 1
    ydirection = sin(azimuth) >= -1e-12 ? -1 : 1
    xmin, ymin, xmax, ymax = prepared.domain
    return [(xdirection * i * (xmax - xmin), ydirection * j * (ymax - ymin))
        for j in 0:(ny - 1) for i in 0:(nx - 1)]
end

function _configuration_repeats(prepared; repeats=(2, 2), repeat_x_width=5.0)
    nx, ny = repeats
    nx isa Integer && ny isa Integer && nx > 0 && ny > 0 ||
        throw(ArgumentError("repeats must contain two positive integer tile counts."))
    isfinite(repeat_x_width) && repeat_x_width >= 0 ||
        throw(ArgumentError("repeat_x_width must be finite and nonnegative."))
    xmin, _, xmax, _ = prepared.domain
    return (max(nx, ceil(Int, repeat_x_width / (xmax - xmin))), ny)
end

function _configuration_box!(ax, prepared; fontsize=20, view=:threequarter)
    xmin, ymin, xmax, ymax = prepared.domain
    zmin, zmax = prepared.bounds[3]
    corners = [Point3f(x, y, z) for z in (zmin, zmax) for y in (ymin, ymax) for x in (xmin, xmax)]
    edges = ((1, 2), (1, 3), (2, 4), (3, 4), (5, 6), (5, 7), (6, 8), (7, 8),
        (1, 5), (2, 6), (3, 7), (4, 8))
    linesegments!(ax, [corners[i] for edge in edges for i in edge];
        color=RGBf(0.15, 0.15, 0.15), linewidth=1.2)

    camera = _configuration_camera(view)
    azimuth = agripv_local_camera_azimuth(prepared.rotation;
        geographic_azimuth_deg=camera.geographic_azimuth_deg)
    xfront = cos(azimuth) >= -1e-12 ? xmax : xmin
    yfront = sin(azimuth) >= -1e-12 ? ymax : ymin
    xsign = cos(azimuth) >= -1e-12 ? 1 : -1
    ysign = sin(azimuth) >= -1e-12 ? 1 : -1
    dx, dy = xmax - xmin, ymax - ymin
    horizontal_span = max(dx, dy)
    label_scale = max(horizontal_span, zmax - zmin)
    label_gap = 0.20 * horizontal_span
    # Keep captions below the ground plane: a label at zmin is hidden by
    # the foreground canopy even when its horizontal anchor is outside it.
    caption_z = zmin - 0.06 * label_scale
    xcaption = Point3f((xmin + xmax) / 2, yfront + ysign * label_gap, caption_z)
    ycaption = Point3f(xfront + xsign * label_gap, (ymin + ymax) / 2, caption_z)
    # Text grows outward from its anchor, away from the opaque canopy.
    # Centering long captions lets the mesh hide the end of the label.
    outward_align(component) = abs(component) < 1e-12 ? :center : component > 0 ? :left : :right
    xalign = outward_align(ysign * cos(azimuth))
    yalign = outward_align(-xsign * sin(azimuth))
    text!(ax, xcaption;
        text="local x (m)", fontsize, align=(xalign, :top))
    text!(ax, ycaption;
        text="local y (m)", fontsize, align=(yalign, :top))
    # The vertical ruler collapses in a view from above, obscuring the cell.
    if view == :top
        label_points = Point3f[xcaption, ycaption]
        return (; bounds=ntuple(i -> extrema(point[i] for point in label_points), 3))
    end
    # Use the leftmost box edge for z labels, away from the foreground canopy.
    horizontal = (-sin(azimuth), cos(azimuth))
    zcorner = (horizontal[1] >= 0 ? xmin : xmax, horizontal[2] >= 0 ? ymin : ymax)
    # Separate the vertical caption from the tick numbers in screen space.
    tick_gap = 0.08 * label_scale
    zcaption_gap = 0.27 * label_scale
    zcaption = Point3f(zcorner[1] - horizontal[1] * zcaption_gap,
        zcorner[2] - horizontal[2] * zcaption_gap, (zmin + zmax) / 2)
    text!(ax, zcaption;
        text="z (m)", fontsize, rotation=pi / 2, align=(:center, :center))
    label_points = Point3f[xcaption, ycaption, zcaption]
    for z in 0:2:floor(Int, zmax)
        tick = Point3f(zcorner[1] - horizontal[1] * tick_gap,
            zcorner[2] - horizontal[2] * tick_gap, z)
        push!(label_points, tick)
        text!(ax, tick;
            text=string(z), fontsize=fontsize - 3, align=(:center, :center))
    end
    return (; bounds=ntuple(i -> extrema(point[i] for point in label_points), 3))
end

function _configuration_axis!(position, prepared; repeats=(2, 2), repeat_alpha=0.18,
    fontsize=20, view=:threequarter, shading=GLMakie.Makie.automatic)
    0 < repeat_alpha < 1 || throw(ArgumentError("repeat_alpha must lie strictly between zero and one."))
    camera = _configuration_camera(view)
    offsets = _configuration_offsets(prepared; repeats,
        geographic_azimuth_deg=camera.geographic_azimuth_deg)
    xmin, ymin, xmax, ymax = prepared.domain
    ax = Axis3(position; aspect=:data, perspectiveness=0, viewmode=:fitzoom,
        azimuth=agripv_local_camera_azimuth(prepared.rotation;
            geographic_azimuth_deg=camera.geographic_azimuth_deg), elevation=camera.elevation,
        title="Config $(prepared.config_id) · scene rotation $(prepared.rotation |> Int)°\n$(xmax - xmin) × $(ymax - ymin) m simulated cell",
        titlefont=:bold, titlesize=fontsize + 2, protrusions=(15, 15, 20, 85),
        xspinesvisible=false, yspinesvisible=false, zspinesvisible=false,
        xypanelvisible=false, xzpanelvisible=false, yzpanelvisible=false)
    hidedecorations!(ax)
    for (dx, dy) in offsets
        original = dx == 0 && dy == 0
        p = mesh!(ax, prepared.mesh; color=original ? prepared.colors : prepared.ghost_colors,
            alpha=original ? 1.0 : repeat_alpha, transparency=!original, shading)
        translate!(p, dx, dy, 0)
    end
    box = _configuration_box!(ax, prepared; fontsize, view)
    horizontal_span = max(xmax - xmin, ymax - ymin)
    annotation_span = max(horizontal_span, prepared.bounds[3][2] - prepared.bounds[3][1])
    compass = agripv_cardinal_arrow!(ax, prepared.domain, prepared.rotation; fontsize,
        cardinal=:north, geographic_azimuth_deg=camera.geographic_azimuth_deg,
        domain_gap_fraction=0.70 * annotation_span / horizontal_span, label_gap_fraction=0.60,
        label_align=view == :top ? (:center, :bottom) : (:right, :bottom))
    xoffsets, yoffsets = first.(offsets), last.(offsets)
    xbounds, ybounds, zbounds = prepared.bounds
    xlims = (min(xbounds[1] + minimum(xoffsets), compass.bounds[1][1], box.bounds[1][1]),
        max(xbounds[2] + maximum(xoffsets), compass.bounds[1][2], box.bounds[1][2]))
    ylims = (min(ybounds[1] + minimum(yoffsets), compass.bounds[2][1], box.bounds[2][1]),
        max(ybounds[2] + maximum(yoffsets), compass.bounds[2][2], box.bounds[2][2]))
    zlims = (min(zbounds[1], compass.bounds[3][1], box.bounds[3][1]),
        max(zbounds[2], compass.bounds[3][2], box.bounds[3][2]))
    margin = max(0.06 * max(xlims[2] - xlims[1], ylims[2] - ylims[1]),
        0.13 * max(xmax - xmin, ymax - ymin))
    limits!(ax, xlims[1] - margin, xlims[2] + margin,
        ylims[1] - margin, ylims[2] + margin, zlims[1] - 0.15, zlims[2] + 0.15)
    return ax
end

"""Use one metre-to-screen scale, without changing the saved local geometry."""
function _configuration_match_scales!(axes; spans=nothing)
    bounds = [ax.finallimits[] for ax in axes]
    if isnothing(spans)
        horizontal = maximum(max(rect.widths[1], rect.widths[2]) for rect in bounds)
        vertical = maximum(rect.widths[3] for rect in bounds)
        spans = (horizontal, horizontal, vertical)
    end
    # A square horizontal frame is invariant to the configurations' 90°/180°
    # bearings. With :data aspect, :fitzoom and equal panel sizes, the physical
    # scale is identical instead of zooming each design to fill its panel.
    for (ax, rect) in zip(axes, bounds)
        center = rect.origin + rect.widths / 2
        limits!(ax, (center[1] - spans[1] / 2, center[1] + spans[1] / 2),
            (center[2] - spans[2] / 2, center[2] + spans[2] / 2),
            (center[3] - spans[3] / 2, center[3] + spans[3] / 2))
    end
    return spans
end

function _configuration_footer(figure, row, day; repeated, columns=1, view=:threequarter)
    meaning = repeated ? "Opaque: simulated cell   ·   Faded: periodic repetitions" : "Outlined: simulated cell"
    direction = view == :top ? "North ↑ · South ↓" : "N: geographic north"
    Label(figure[row, 1:columns], "$meaning\nSame scale in all panels   ·   $direction   ·   Geometry: $day";
        fontsize=19, color=RGBf(0.35, 0.35, 0.35), padding=(0, 0, 8, 8), tellwidth=false)
end

"""
    plot_configurations(; config_ids=0:3, day=nothing, repeats=(2,2), repeat_x_width=5.0, ...)

Export each saved configuration as a single cell and with translucent periodic
copies, plus one combined repeated-design figure. The opaque cell and its box
are the simulated domain; copies share the original mesh and use exact saved
domain periods. Local geometry is unchanged; the camera has one common
geographic southwest viewing direction and the north arrow uses the simulation
rotation. Copies stay above the foreground cell in the image. At least 5 m of
local-x context is shown by default: five cells for configs 0/1 and two for 2/3.
All configurations share one physical scale. Set `repeat_x_width=0` to use only
the explicit `repeats` counts.
Default to the last saved scene date common to all requested configurations.
Run through Kaimon with `mt=true`; no simulation is executed.
"""
function plot_configurations(; config_ids=0:3, day=nothing, repeats=(2, 2), repeat_x_width=5.0, repeat_alpha=0.18,
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
    end
    figure = Figure(size=(1600, 1500), fontsize=22, backgroundcolor=:white)
    columns = min(2, length(geometries))
    Label(figure[0, 1:columns], "Periodic AgriPV configurations"; fontsize=30, font=:bold, tellwidth=false)
    axes = Axis3[]
    tile_counts = [_configuration_repeats(prepared; repeats, repeat_x_width) for prepared in geometries]
    for (i, prepared) in enumerate(geometries)
        row, col = divrem(i - 1, columns)
        push!(axes, _configuration_axis!(figure[row + 1, col + 1], prepared;
            repeats=tile_counts[i], repeat_alpha, fontsize=21))
    end
    spans = _configuration_match_scales!(axes)
    _configuration_footer(figure, cld(length(geometries), columns) + 1, day; repeated=true, columns)
    path = joinpath(output_dir, "configurations_repeated.png")
    save(path, figure; px_per_unit=2)
    push!(paths, path)
    GLMakie.closeall()
    empty!(axes)
    figure = nothing
    GC.gc()
    for (prepared, tiles) in zip(geometries, tile_counts), repeated in (false, true)
        figure = Figure(size=(1100, 1000), fontsize=22, backgroundcolor=:white)
        ax = _configuration_axis!(figure[1, 1], prepared;
            repeats=repeated ? tiles : (1, 1), repeat_alpha, fontsize=22)
        _configuration_match_scales!([ax]; spans)
        _configuration_footer(figure, 2, day; repeated)
        suffix = repeated ? "_repeated" : ""
        path = joinpath(output_dir, "config_$(prepared.config_id)$(suffix).png")
        save(path, figure; px_per_unit=2)
        push!(paths, path)
        GLMakie.closeall()
        GC.gc()
    end
    return (; day, repeats, repeat_x_width, tile_counts, repeat_alpha, spans, paths)
end

"""
    plot_configuration_topviews(; config_ids=0:3, day=nothing, ...)

Export each saved experimental configuration viewed from above, plus one
combined figure. All views use geographic North up, South down and East right,
applying the saved simulation rotation to the camera and compass. The camera
is orthographic at 89.9° elevation, avoiding a singular camera basis at exact
zenith while keeping height parallax negligible. The simulated cell is opaque
and outlined; translucent periodic copies show the repeated design. All panels
share one physical scale. The repeat settings match `plot_configurations`.
Default to the latest saved scene date common to all requested configurations.
Run through Kaimon with `mt=true`; no simulation is executed.
"""
function plot_configuration_topviews(; config_ids=0:3, day=nothing,
    repeats=(2, 2), repeat_x_width=5.0, repeat_alpha=0.18,
    input_dir=_agripv_yearly_output_dir(), output_dir=joinpath(_agripv_project_root(), "2_outputs"))
    config_ids = collect(config_ids)
    !isempty(config_ids) && length(unique(config_ids)) == length(config_ids) ||
        throw(ArgumentError("Provide a nonempty set of unique configuration IDs."))
    day = _configuration_saved_day(config_ids, input_dir, day)
    mkpath(output_dir)
    geometries = Any[]
    paths = String[]
    for config_id in config_ids
        @info "Rendering saved configuration from above" config_id day
        prepared = _configuration_geometry(; config_id, day, output_dir=input_dir)
        push!(geometries, prepared)
        GC.gc()
    end
    figure = Figure(size=(1600, 1500), fontsize=22, backgroundcolor=:white)
    columns = min(2, length(geometries))
    Label(figure[0, 1:columns], "AgriPV configurations · view from above";
        fontsize=30, font=:bold, tellwidth=false)
    axes = Axis3[]
    tile_counts = [_configuration_repeats(prepared; repeats, repeat_x_width) for prepared in geometries]
    for (i, prepared) in enumerate(geometries)
        row, col = divrem(i - 1, columns)
        push!(axes, _configuration_axis!(figure[row + 1, col + 1], prepared;
            repeats=tile_counts[i], repeat_alpha, fontsize=21, view=:top))
    end
    spans = _configuration_match_scales!(axes)
    _configuration_footer(figure, cld(length(geometries), columns) + 1, day;
        repeated=true, columns, view=:top)
    path = joinpath(output_dir, "configurations_top.png")
    save(path, figure; px_per_unit=2)
    push!(paths, path)
    GLMakie.closeall()
    empty!(axes)
    figure = nothing
    GC.gc()
    for (prepared, tiles) in zip(geometries, tile_counts)
        figure = Figure(size=(1100, 1000), fontsize=22, backgroundcolor=:white)
        ax = _configuration_axis!(figure[1, 1], prepared; repeats=tiles,
            repeat_alpha, fontsize=22, view=:top)
        _configuration_match_scales!([ax]; spans)
        _configuration_footer(figure, 2, day; repeated=true, view=:top)
        path = joinpath(output_dir, "config_$(prepared.config_id)_top.png")
        save(path, figure; px_per_unit=2)
        push!(paths, path)
        GLMakie.closeall()
        GC.gc()
    end
    return (; day, view=:top, repeats, repeat_x_width, tile_counts, repeat_alpha, spans, paths)
end
