using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using PlantGeom # For the growth and visualization API
using ArchimedLight
using GLMakie

include("pvconfig.jl")
include("scene.jl")
include("simulation.jl")

configID::Int8 = 0

options = LightOptions(
    turtle_sectors=16,
    pixel_size=0.01,
    toricity=true,
    scattering=true,
    all_in_turtle=true,
    cache_radiation=false,
)

config = get_pvconfig(configID)
models = agripv_models()

@time scene = agripv_scene(c=config)
sim = LightSimulation(scene, models; options=options)
update_options!(
    sim,
    LightOptions(sim.options; scene_rotation_deg=config.panel_orientation),
)

# TODO
values_dict = read_component_values(csv_path="2_outputs/simulations/static/results_config$configID.csv")
# component_values = CSV.read("2_outputs/simulations/static/results_config$configID.csv")

# stp = LightStepResult(
#     sky,

# )
# stp.node_id = component_values[:node_id]
# stp.incident_flux.total.par = component_values[:]

# attach_light_step!(scene, stp)

wheat_plant = read_opf("0_simulations/archicrop/wheat/static/plant_1995-06-24.opf", mtg_type=NodeMTG)
tiled = ArchimedLight.tile_light_geometry(scene, models, options; nx=5, ny=2)
begin
    f = Figure(size=(900, 700))
    ax2 = Axis3(
        f[1, 1],
        aspect=:data,
        title="Incident PAR on a scene with fixed solar panels and a wheat crop",
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
        # azimuth=0.0
    )
    # p = ArchimedLight.lightplot!(ax2, scene, models, options, values_dict; color=values_dict, colormap=:thermal)
    p = ArchimedLight.lightplot!(ax2, tiled, values_dict; color=values_dict, colormap=:thermal)


    # Inset axis
    ax_inset = Axis3(
        f[1, 1],
        width=Relative(0.2),
        height=Relative(0.2),
        halign=1.0,
        valign=0.8,
        aspect=:data,
        title="Individual wheat plant",
        # xticklabelsvisible=false,
        # yticklabelsvisible=false,
        # zticklabelsvisible=false,
        xticklabelsize=10,
        yticklabelsize=10,
        zticklabelsize=10,
        xticks=[-0.2, 0.2],
        yticks=[-0.2, 0.2],
        xlabel="",
        ylabel="",
        zlabel="",
    )

    plantviz!(
        ax_inset,
        wheat_plant;
        color=:green,
    )

    Colorbar(f[1, 2], p, label="Incident PAR (W m⁻²)")
    f
    # hidedecorations!(ax_inset)
end

save("2_outputs/static_config$configID.png", f, update=false, px_per_unit=3.0)