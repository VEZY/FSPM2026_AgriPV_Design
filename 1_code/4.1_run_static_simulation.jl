using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using PlantGeom # For the growth and visualization API
using ArchimedLight

include("pvconfig.jl")
include("scene.jl")

models = agripv_models()
configIDs = range(0, 0)

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

for configID in configIDs
    plant_density = 60.0
    n_rows = 5
    configID::Int8 = id
    config = get_pvconfig(configID)

    # The phenological stage of plants is determined by the `day` parameter of `agripv_scene()`. Default value is Date(2025, 6, 25)
    @time scene = agripv_scene(
        plant_density=plant_density,
        n_rows=n_rows,
        c=config
    )
    options.scene_rotation_deg = config.panel_orientation

    traverse!(scene.mtg) do node
        if symbol(node) == :Leaf
            node[:color] = node[:is_green] == true ? :green : :yellow
        end
        symbol(node) == :Stem && (node[:color] = :green)
        symbol(node) == :Panel && (node[:color] = :black)
    end

    sim = LightSimulation(scene, models; options=options)

    @time stps = run_light(sim, sky; step_duration_seconds=1800.0) # 177.779756 seconds for the full scene with scattering

    @time write_component_values("2_outputs/simulations/simple/results_config$configID.csv", sim, stps)
end