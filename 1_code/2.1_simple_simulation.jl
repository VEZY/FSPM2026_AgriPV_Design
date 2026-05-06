using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using PlantGeom # For the growth and visualization API
using GLMakie
using ArchimedLight

function wheat_models()
    models_for(
        "wheat" => (
            "Stem" => translucent(par=0.15, nir=0.90),
            "Leaf" => translucent(par=0.15, nir=0.90),
        ),
        "panel" => (
            "Panel" => translucent(par=0.0, nir=0.0),
        ),
        "pavement" => (
            "Cobblestone" => translucent(par=0.12, nir=0.60),
        ),
    )
end

function wheat_scene(;
    plant_density=60.0,
    interrow=0.20,
    n_rows=2,
    panel_length=4.2,
    panel_inclination=25.0,
    panel_height=4.0,
    panel_y_distance=10.0,
)
    intrarow = 1.0 / (plant_density * interrow)
    plants_per_row = max(1, floor(Int, panel_y_distance / intrarow) - 1)
    panel_width = interrow * n_rows
    wheat_plant = read_opf("0_simulations/archicrop/wheat/plant_1995-06-24.opf", mtg_type=NodeMTG)
    panel = Agrivoltaics.Fixed(
        panel_dimensions=(panel_width, panel_length),
        inclination=panel_inclination,
        panel_height=panel_height,
    ) |> structure

    return PlantGeom.make_scene(domain=(0.0, 0.0, panel_width, panel_y_distance)) do s
        add_object!(s, panel; group="panel", type="Panel", id=1)

        for i in 1:(plants_per_row * n_rows)
            row = (i - 1) ÷ plants_per_row
            col = (i - 1) % plants_per_row
            add_plant!(
                s,
                wheat_plant;
                group="wheat",
                id=i + 1,
                at=((row + 0.5) * interrow, (col + 0.5) * intrarow, 0.0),
                rotate=(z=randn() * 5.0,),
                deg=true,
            )
        end

        add_ground!(s; nx=60, ny=60, group="pavement", type="Cobblestone")
    end
end

scene = wheat_scene(
    plant_density=60.0,
    interrow=0.20,
    n_rows=5,
    panel_length=4.2,
    panel_inclination=25.0,
    panel_height=4.0,
)

traverse!(scene.mtg) do node
    if symbol(node) == :Leaf
        node[:color] = node[:is_green] == true ? :green : :yellow
    end
    symbol(node) == :Stem && (node[:color] = :green)
    symbol(node) == :Panel && (node[:color] = :black)
end

# f, ax, p = plantviz(scene.mtg, figure=(size=(1080, 720),), color=:color)
# save("2_outputs/simple_plant_scene.png", f, update=false, px_per_unit=3.0)

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
)

function run_archimed(options, sky, scene, models)
    sim = LightSimulation(scene, models; options=options)
    return run_light(sim, sky; step_duration_seconds=1800.0)
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
