using SolarPosition, Dates, TimeZones
using Agrivoltaics
using ArchimedLight
using PlantGeom
using GeometryBasics
using MultiScaleTreeGraph
using GLMakie

panel = Agrivoltaics.Fixed(panel_dimensions=(1.0, 4.2), inclination=25.0, panel_height=4.0) |> structure
panel_mesh = PlantGeom.refmesh_to_mesh(panel) 
norms = GeometryBasics.face_normals(panel_mesh.position, panel_mesh.faces)

# apv_system = Agrivoltaics.System(
#     panel,
#     panel_mesh,
#     norms,
#     row_spacing=2.0,
#     interrow_spacing=0.1,
# )

# ground_coverage_ratio = Agrivoltaics.calculate_gcr(apv_system)

scene_width = 10.0      # m (total scene width including margins)
scene_height = 10.0      # m (total scene height including margins)
scene = PlantGeom.make_scene(domain=(-scene_width / 2, 0.0, scene_width / 2, scene_height)) do s
    add_object!(s, panel; group="panel", type="Panel", id=1, at=(0.0, 0.0, 0.0))
    add_ground!(s; nx=120, ny=120, group="pavement", type="Cobblestone")
end

f, ax, p = plantviz(scene.mtg, figure=(size=(1080, 720),))
save("2_outputs/yearly_rad_scene.png", f, update=false, px_per_unit=3.0)

models = models_for(
    "pavement" => (
        "Cobblestone" => translucent(par=0.12, nir=0.60),
    ),
    "panel" => (
        "Panel" => translucent(par=0.0, nir=0.0),
    ),
)

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

sim = LightSimulation(scene, models; options=options)
step = run_light(sim, sky; step_duration_seconds=1800.0)

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
