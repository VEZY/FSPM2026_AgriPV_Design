using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using PlantGeom # For the growth and visualization API
using ArchimedLight

include("0_configs.jl")
include("methods.jl")

ground_res = 60;

for id in range(0, 89)
    plant_density = 60.0
    n_rows = 5
    configID::Int8 = id
    config = get_config(configID)

    @time scene = wheat_scene(
        plant_density=plant_density,
        n_rows=n_rows,
        c = config
    )

    # write_ops("2_outputs/scene/simple_plant_scene.ops", scene.mtg)

    traverse!(scene.mtg) do node
        if symbol(node) == :Leaf
            node[:color] = node[:is_green] == true ? :green : :yellow
        end
        symbol(node) == :Stem && (node[:color] = :green)
        symbol(node) == :Panel && (node[:color] = :black)
    end

    models = wheat_models()

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
        all_in_turtle=true,
        cache_radiation=false,
    )

    sim = LightSimulation(scene, models; options=options)

    @time stps = run_light(sim, sky; step_duration_seconds=1800.0) # 177.779756 seconds for the full scene with scattering

    @time write_component_values("2_outputs/simulations/simple/results_config$configID.csv", sim, stps)
end