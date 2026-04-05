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

traverse!(scene.mtg) do node
    if symbol(node) == :Leaf
        node[:color] = node[:is_green] == true ? :green : :yellow
    end
    symbol(node) == :Stem && (node[:color] = :green)
    symbol(node) == :Panel && (node[:color] = :black)
end

# f, ax, p = plantviz(scene.mtg, figure=(size=(1080, 720),), color=:color)
# save("2_outputs/simple_plant_scene.png", f, update=false, px_per_unit=3.0)

models = MakeScene.models("wheat")

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
    render_geometry = ArchimedLight.light_render_geometry(scene, models, options)
    step = LightStepResult(sky, turtle, fluxes, first, scat, budget, Dict{String,Float64}(), render_geometry)

    return step
end

@time step = run_archimed(options, sky, scene, models) # 30s for the full scene with scattering

# # Tiled:
# tiled = ArchimedLight.tile_light_geometry(scene, step; nx=15, ny=3)
# fig, ax, p = ArchimedLight.lightplot(tiled, step; color=:Ri_PAR_f)
# save("2_outputs/simple_plant_scene_light_scat_repeated.png", fig, update=false, px_per_unit=3.0)


# tiled = ArchimedLight.tile_light_geometry(scene, step; nx=15, ny=3)

wheat_plant = read_opf("0_simulations/archicrop/wheat/plant_1995-06-24.opf", mtg_type=NodeMTG)
tiled = ArchimedLight.tile_light_geometry(scene, step; nx=15, ny=3)
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
    p = ArchimedLight.lightplot!(ax2, tiled, step; color=:Ri_PAR_f, colormap=:thermal)


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
    # hidedecorations!(ax_inset)
end

save("2_outputs/simple_plant_scene_light_scat_repeated_plant.png", f, update=false, px_per_unit=3.0)