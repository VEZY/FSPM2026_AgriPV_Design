using GLMakie
using PlantGeom
using Colors

include("scene.jl")
include("pvconfig.jl")

configID::Int8 = 0

f = Figure(size=(900, 700))
config = get_pvconfig(configID)

@time scene = agripv_scene(c=config)

ax = Axis3(
    f[1, 1],
    aspect=:data,
    title="Config $configID",
    xlabel="x (m)",
    ylabel="y (m)",
    zlabel="z (m)",
)

plantviz!(ax, scene.mtg; color=Dict("Plant" => :green, "Panel" => :black))
ax.azimuth[]=deg2rad(45)
ax.elevation[]=deg2rad(30)
f

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