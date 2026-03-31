using SolarPosition, Dates, TimeZones
using Agrivoltaics
using ArchimedLight
using PlantGeom
using GeometryBasics
using MultiScaleTreeGraph
using GLMakie
using OrderedCollections: OrderedDict

panel = Agrivoltaics.Fixed(panel_dimensions=(1.0, 4.2), inclination=25.0, panel_height=4.0) |> structure
panel_mesh = refmesh_to_mesh(panel) 
norms = face_normals(panel_mesh.position, panel_mesh.faces)

scene_width = 10.0      # m (total scene width including margins)
scene_height = 10.0      # m (total scene height including margins)
# Make the scene node:
scene_mtg = Node(NodeMTG(:/, :Scene, 1, 1))
# Set scene dimensions
scene_mtg.scene_dimensions = (
    Point3(-scene_width/2, 0.0, 0.0),
    Point3(scene_width/2, scene_height, 0.0)
)

# Place the solar panel in the scene:
place_in_scene!(
    panel;
    scene=scene_mtg,
    scene_id=1,
    plant_id=1,
    functional_group="panel",
    pos=(0.0, 0.0, 0.0),
    # scale=1.15,
    # rotation=-0.35,
    # inclination_angle=0.12,
)

f, ax, p = plantviz(scene_mtg, figure=(size=(1080, 720),))
save("2_outputs/yearly_rad_scene.png", f, update=false, px_per_unit=3.0)

# Make the Archimed Light scene and add the ground:
scene = prepare_scene(scene_mtg)

add_ground!(
    scene;
    nx=120,
    ny=120,
    # xy_bounds=(0.0, 0.0, 1.0, 10.0),
    group="pavement",
    type="Cobblestone",
)


models = prepare_models([
    GroupModel(
        "pavement";
        types=OrderedDict(
            "Cobblestone" => TypeModel(
                interception=InterceptionModel(
                    model="Translucent",
                    transparency=0.0,
                    optical_properties=OpticalProperties(0.12, 0.60),
                ),
            ),
        ),
    ),
    GroupModel(
        "panel";
        types=OrderedDict(
            "Panel" => TypeModel(
                interception=InterceptionModel(
                    model="Translucent",
                    transparency=0.0,
                    optical_properties=OpticalProperties(0.0, 0.0),
                ),
            ),
        ),
    ),
])

obs = Observer(43.61246, 3.87918, 10.0) # Montpellier, France, 10m above sea level
tz = TimeZone("Europe/Paris")
zdt = ZonedDateTime(2025, 10, 12, 12, 0, 0, 0, tz)
#zdt = collect(ZonedDateTime(2025, tz):Hour(1):ZonedDateTime(2026, tz))  # Summer solstice noon
sun_pos = solar_position(obs, zdt)

sky = SkyState(
    sun_pos.azimuth,  # sun azimuth in degrees
    sun_pos.elevation,   # sun elevation in degrees
    350.0,  # PAR irradiance on horizontal ground, W m^-2
    250.0,  # NIR irradiance on horizontal ground, W m^-2
    0.60,   # direct fraction
    0.40,   # diffuse fraction
)

options = LightOptions(
    turtle_sectors=16,
    pixel_size=0.01,
    toricity=true,
    scattering=true,
)

turtle = build_turtle(options, sky)
fluxes = compute_directional_fluxes(sky, turtle, options)
first = compute_first_order(scene, models, turtle, fluxes, options)
scat = compute_scattering(scene, models, turtle, first, options)
budget = integrate_light(scene, models, first, scat, options; step_duration_seconds=1800.0)

step = LightStepResult(sky, turtle, fluxes, first, scat, budget, Dict{String,Float64}())

# Attach the results to the MTG for visualization:
attach_light_step!(scene, step; fields=[:incident_par_flux, :absorbed_par_energy, :absorbed_par_flux])

# Make the plot:
begin
    f = Figure(size=(900, 700))
    # ax = Axis3(f[1, 1], azimuth=0.0)
    ax = Axis3(f[1, 1], aspect=:data, title="Incident PAR with a simple plant stand and a solar panel")
    p = plantviz!(
        ax,
        scene.mtg;
        color=:Ri_PAR_f,
        # color=:Ra_PAR_f,
        colormap=:thermal,
        color_missing=:gray85,
    )

    # ax.show_axis[] = false
    PlantGeom.colorbar(f[1, 2], p, label="Incident PAR (W m^-2)")
    f
end

save("2_outputs/yearly_rad_integrated.png", f, update=false, px_per_unit=3.0)