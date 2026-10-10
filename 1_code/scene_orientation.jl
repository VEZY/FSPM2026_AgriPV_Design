using GLMakie, GeometryBasics, PlantGeom

"""The orientation retained in a saved scene recipe, without consulting the DOE."""
function agripv_scene_rotation_deg(scene_or_mtg)
    mtg = scene_or_mtg isa PlantGeom.SceneGeometry ? scene_or_mtg.mtg : scene_or_mtg
    recipe = mtg[:agripv_scene_recipe]
    recipe isa AbstractDict && get(recipe, "config", nothing) isa AbstractDict ||
        throw(ArgumentError("A geographic orientation requires the saved scene configuration."))
    rotation = get(recipe["config"], "panel_orientation", nothing)
    rotation isa Real && isfinite(rotation) ||
        throw(ArgumentError("The saved scene rotation must be finite degrees."))
    return Float64(rotation)
end

"""
    agripv_local_cardinal_directions(scene_rotation_deg)

Geographic north/east/up in the unchanged scene-local mesh coordinates.
ArchimedLight transforms geographic (east, north, up) directions to local
coordinates with `(c*east + s*north, -s*east + c*north, up)`, where
`c=cos(rotation)` and `s=sin(rotation)` (`src/turtle.jl:_scene_local_direction`).
Thus north is `(sin(rotation), cos(rotation), 0)`; this is a coordinate change,
not another rotation of the saved geometry.
"""
function agripv_local_cardinal_directions(scene_rotation_deg::Real)
    isfinite(scene_rotation_deg) || throw(ArgumentError("Scene rotation must be finite degrees."))
    s, c = sind(scene_rotation_deg), cosd(scene_rotation_deg)
    return (; north=(s, c, 0.0), east=(c, -s, 0.0), up=(0.0, 0.0, 1.0))
end

"""
    agripv_local_camera_azimuth(scene_rotation_deg; geographic_azimuth_deg=45)

Makie azimuth is counterclockwise from geographic east. Apply the same
geographic-to-local change of basis as the sun so every configuration is
viewed from the same geographic direction. A 45° view is northeast.
"""
function agripv_local_camera_azimuth(scene_rotation_deg::Real; geographic_azimuth_deg=45.0)
    all(isfinite, (scene_rotation_deg, geographic_azimuth_deg)) ||
        throw(ArgumentError("Scene rotation and geographic camera azimuth must be finite degrees."))
    return deg2rad(geographic_azimuth_deg - scene_rotation_deg)
end

function _agripv_orientation_domain(scene_or_mtg)
    if scene_or_mtg isa PlantGeom.SceneGeometry
        domain = scene_or_mtg.scene_xy_bounds
    else
        dimensions = scene_or_mtg[:scene_dimensions]
        isnothing(dimensions) && throw(ArgumentError("The saved scene has no horizontal domain."))
        a, b = dimensions
        domain = (min(a[1], b[1]), min(a[2], b[2]), max(a[1], b[1]), max(a[2], b[2]))
    end
    isnothing(domain) && throw(ArgumentError("The saved scene has no horizontal domain."))
    length(domain) == 4 && all(isfinite, domain) && domain[1] < domain[3] && domain[2] < domain[4] ||
        throw(ArgumentError("The saved scene domain must have finite positive dimensions."))
    return Float64.(domain)
end

function _agripv_north_arrow_layout(domain, scene_rotation_deg;
    geographic_azimuth_deg=45.0, z=0.02)
    xmin, ymin, xmax, ymax = domain
    all(isfinite, domain) && xmin < xmax && ymin < ymax ||
        throw(ArgumentError("The north arrow requires a finite positive domain."))
    isfinite(z) || throw(ArgumentError("The north arrow height must be finite."))
    azimuth = agripv_local_camera_azimuth(scene_rotation_deg; geographic_azimuth_deg)
    north = agripv_local_cardinal_directions(scene_rotation_deg).north
    xsign = cos(azimuth) >= 0 ? 1 : -1
    ysign = sin(azimuth) >= 0 ? 1 : -1
    span = max(xmax - xmin, ymax - ymin)
    gap = 0.20 * span
    arrow_length = min(0.65, 0.24 * span)
    base = Point3f((xsign > 0 ? xmax : xmin) + xsign * gap,
        (ysign > 0 ? ymax : ymin) + ysign * gap, z)
    direction = Vec3f(north)
    tip = base + arrow_length * direction
    side = Vec3f(-north[2], north[1], 0)
    head_base = tip - 0.22 * arrow_length * direction
    left = head_base + 0.12 * arrow_length * side
    right = head_base - 0.12 * arrow_length * side
    # GLMakie needs one concrete coordinate type; scalar arithmetic above can
    # promote the tip/head to Float64 while the base remains Float32.
    label = Point3f(tip + 0.22 * arrow_length * direction)
    points = Point3f[base, tip, left, tip, right, tip]
    bounds = ntuple(i -> extrema(point[i] for point in [points; [label]]), 3)
    return (; points, label, bounds, direction=north)
end

"""Draw geographic north outside a local domain, using the saved simulation rotation."""
function agripv_north_arrow!(axis, domain::NTuple{4,<:Real}, rotation::Real;
    fontsize=20, geographic_azimuth_deg=45.0)
    layout = _agripv_north_arrow_layout(domain, rotation;
        geographic_azimuth_deg)
    linesegments!(axis, layout.points; color=:black, linewidth=2.5)
    text!(axis, layout.label; text="N", fontsize, font=:bold, align=(:center, :center))
    return layout
end

"""Draw geographic north from the domain and orientation of a saved scene."""
function agripv_north_arrow!(axis, scene_or_mtg; kwargs...)
    return agripv_north_arrow!(axis, _agripv_orientation_domain(scene_or_mtg),
        agripv_scene_rotation_deg(scene_or_mtg); kwargs...)
end
