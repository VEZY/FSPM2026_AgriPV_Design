using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using OrderedCollections: OrderedDict
using PlantGeom # For the growth and visualization API
using GLMakie
using ArchimedLight

# Add custome module:
includet("0_make_scene.jl") # Requires Revise to be installed. Else, remove the "t" in includet and re-run the code after editing 0_make_scene.jl to see the changes.
using .MakeScene

scene = MakeScene.make_scene(scene_dimensions=(x=1.0, y=10.0), plant_density=60.0, interrow=0.20, panel_dimensions=(1.0, 4.2), panel_inclination=25.0, panel_height=4.00)

f, ax, p = plantviz(scene.mtg, figure=(size=(1080, 720),))

save("2_outputs/simple_plant_scene.png", f, update=false, px_per_unit=3.0)

models = MakeScene.models()


sky = SkyState(
    135.0,  # sun azimuth in degrees
    60.0,   # sun elevation in degrees
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

function run_archimed(options, sky, scene, models)
    turtle = build_turtle(options, sky)
    fluxes = compute_directional_fluxes(sky, turtle, options)
    first = compute_first_order(scene, models, turtle, fluxes, options)
    scat = compute_scattering(scene, models, turtle, first, options)
    budget = integrate_light(scene, models, first, scat, options; step_duration_seconds=1800.0)
    step = LightStepResult(sky, turtle, fluxes, first, scat, budget, Dict{String,Float64}())

    return step
end

@time step = run_archimed(options, sky, scene, models)

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

save("2_outputs/simple_plant_scene_light_scat.png", f, update=false, px_per_unit=3.0)