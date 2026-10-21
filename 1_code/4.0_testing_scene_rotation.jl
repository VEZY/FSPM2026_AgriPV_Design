using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using PlantGeom # For the growth and visualization API
using ArchimedLight
using GLMakie

include("pvconfig.jl")
include("scene.jl")

models = agripv_models()

begin
    f = Figure(resolution=(1200, 800), fontsize=16)
    plots_structs = []
    for (i, scene_rotation_deg) in enumerate([0, 180])
        sky = SkyState(
            180.0,  # sun azimuth in degrees
            70.0,   # sun elevation in degrees
            350.0,  # PAR irradiance on horizontal ground, W m^-2
            250.0,  # NIR irradiance on horizontal ground, W m^-2
            1.00,   # direct fraction
            0.00,   # diffuse fraction
        )

        configID = 0
        config = get_pvconfig(configID)

        options = LightOptions(
            turtle_sectors=46,
            pixel_size=0.01,
            toricity=true,
            scattering=true,
            all_in_turtle=true,
            cache_radiation=true,
            scene_rotation_deg=scene_rotation_deg # panel to the south, sun to the south, 0° azimuth
        )
        # The phenological stage of plants is determined by the `day` parameter of `agripv_scene()`. Default value is Date(2025, 6, 25)
        scene = agripv_scene(c=config)
        sim = LightSimulation(scene, models; options=options)
        tps = run_light(sim, sky; step_duration_seconds=1800.0) # 177.779756 seconds for the full scene with scattering
        # lightplot(sim.scene, stps)
        ax = Axis3(f[1, i], title="Scene rotation = $(scene_rotation_deg)°", aspect=:data)
        push!(plots_structs, lightplot!(ax, tps, colorrange=(0.0, 450.0), colormap=:viridis, shading=NoShading))
    end
    Colorbar(
        f[1, 3], plots_structs[1];
        label="Incident PAR (W m⁻²)",
    )
    f
end


# plantviz(scene.mtg)
