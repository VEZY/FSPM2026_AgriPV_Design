using GLMakie
using PlantGeom
using Colors
using ArchimedLight

include("scene.jl")
include("pvconfig.jl")
include("meta4glmakie.jl")

configID = 1
only3D = false

function tile_geometry(scene; nx=5, ny=2)
    models = agripv_models()  # or MakeScene.models("wheat")
    options = LightOptions(
        turtle_sectors=16,
        pixel_size=0.01,
        toricity=true,
        scattering=true,
    )

    tiled_scene = ArchimedLight.tile_light_geometry(scene, models, options; nx=nx, ny=ny)

    # tiled_mtg = copy(scene.mtg)
    # for i in 0:4  # 5x along x-axis
    #     for j in 0:1  # 2x along y-axis
    #         if i == 0 && j == 0
    #             continue  # Skip the original (already included)
    #         end
    #         # Translate all nodes in the scene by (i * scene_width, j * scene_height, 0)
    #         scene_width = scene.domain[3]  # x-dimension of the scene
    #         scene_height = scene.domain[4]  # y-dimension of the scene
    #         traverse!(scene.mtg) do node
    #             if haskey(node, :geometry)
    #                 new_geom = deepcopy(node[:geometry])
    #                 # Apply translation to the geometry
    #                 new_geom.transform = Translation(i * scene_width, j * scene_height, 0.0) ∘ new_geom.transform
    #                 # Add the translated geometry to the tiled MTG
    #                 # (This part depends on how PlantGeom handles geometry transformations)
    #             end
    #         end
    #     end
    # end

    return tiled_scene
end


config = get_pvconfig(configID)

@time scene = agripv_scene(c=config)
# tile_scene = tile_geometry(scene)

traverse!(scene.mtg) do node
    if symbol(node) == :LeafSection
        if node[:state] == "active"
            node[:color] = RGB(0.2, 0.8, 0.0) # Green for active leaves
        elseif node[:state] == "senescent"
            node[:color] = RGB(0.72, 0.65, 0.38) # Orange for senescent leaves
        end
    elseif symbol(node) == :Stem
        node[:color] = RGB(0.1, 0.4, 0.0) # Dark Green for stems
    elseif symbol(node) == :Panel
        node[:color] = RGB(0.0, 0.0, 0.0) # Black for panels
    elseif symbol(node) == :Cobblestone
        node[:color] = RGB(0.58, 0.49, 0.37) # Gray for cobblestones
    end
end

begin
    f = Figure(size=(1800, 1400), backgroundcolor=(:white, 0.01))
    azimuth_offset = 45 # With azimuth_offset=45, the South is at the bottom right and the West is at the bottom left of the figure.
    ax = Axis3(
        f[1, 1],
        aspect=:data,
        title="Config $configID",
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
        azimuth=deg2rad(azimuth_offset + config.panel_orientation),
        elevation=deg2rad(30),
    )

    if only3D
        ax.titlevisible=false
        ax.xspinesvisible=false
        ax.yspinesvisible=false
        ax.zspinesvisible=false
        hidedecorations!(ax)
    end

    plantviz!(ax, scene.mtg; color=:color)
    f
end

if only3D
    img_name = "2_outputs/config_$(configID)_only3D.png"
else
    img_name = "2_outputs/config_$(configID).png"
end

save(img_name, alpha_colorbuffer(f), dpi=300)
# save("2_outputs/config_$(configID)_nospines.png", alpha_colorbuffer(f), dpi=300)
# save("2_outputs/config_$(configID)_noaxis.png", background=false)
# save("2_outputs/config_$(configID).png", alpha_colorbuffer(f), update=false, px_per_unit=3.0)


# begin
#     cam = camera_controls(ax.scene)
#     # Définir le point visé (souvent le centre de l'objet)
#     center = (config.panel_x_distance/2.0, config.panel_y_distance/2.0, 0.0)
#     cam.lookat[] = center

#     # Vue de 3/4 : caméra positionnée en diagonale (45° en azimuth)
#     # avec une élévation d'environ 30°
#     r = 10.0                       # distance au centre
#     azimuth = deg2rad(45)           # angle horizontal
#     elevation = deg2rad(30)        # angle vertical

#     cam.eyeposition[] = center .+ r .* (
#         cos(elevation) * cos(azimuth),
#         cos(elevation) * sin(azimuth),
#         sin(elevation)
#     )
#     cam.upvector[] = Vec3f(0, 0, 1) # z vers le haut

#     update_cam!(ax.scene)          # appliquer la vue
# end