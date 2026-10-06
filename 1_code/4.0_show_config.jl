using GLMakie
using PlantGeom
using Colors

include("scene.jl")
include("pvconfig.jl")

configID = 0

config = get_pvconfig(configID)

@time scene = agripv_scene(c=config)


traverse!(scene.mtg) do node
    if symbol(node) == :LeafSection
        if node[:state] == "active"
            node[:color] = RGB(0.2, 0.8, 0.0) # Green for active leaves
        elseif node[:state] == "senescent"
            node[:color] = RGB(0.72, 0.65, 0.38) # Orange for senescent leaves
        end
    elseif symbol(node) == :Panel
        node[:color] = RGB(0.0, 0.0, 0.0) # Black for panels
    elseif symbol(node) == :Cobblestone
        node[:color] = RGB(0.58, 0.49, 0.37) # Gray for cobblestones
    end
end

let
    f = Figure(size=(900, 700))
    ax = Axis3(
        f[1, 1],
        aspect=:data,
        title="Config $configID",
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
    )

    plantviz!(ax, scene.mtg; color=:color)
    ax.azimuth[]=deg2rad(45)
    ax.elevation[]=deg2rad(30)
    f
end


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