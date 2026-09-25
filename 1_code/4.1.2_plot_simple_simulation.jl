using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using PlantGeom # For the growth and visualization API
using ArchimedLight

# TODO
# read_component_values()

wheat_plant = read_opf("0_simulations/archicrop/wheat/static/plant_1995-06-24.opf", mtg_type=NodeMTG)
tiled = ArchimedLight.tile_light_geometry(scene, step; nx=1, ny=1)
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
    f
    # hidedecorations!(ax_inset)
end

save("2_outputs/simple_plant_scene_light_scat_repeated_plant_nx=ny=$(ground_res).png", f, update=false, px_per_unit=3.0)