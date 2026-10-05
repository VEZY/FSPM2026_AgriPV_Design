using GLMakie
using PlantGeom

include("scene.jl")

configIDs = [Int8(x) for x in range(0, 0)]

for configID in configIDs
    begin
        f = Figure(size=(900, 700))
        config = get_pvconfig(configID)

        @time scene = agripv_scene(c=config)

        ax_inset = Axis3(
            f[1, 1],
            width=Relative(0.2),
            height=Relative(0.2),
            halign=1.0,
            valign=0.8,
            aspect=:data,
            title="Config $configID",
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

        plantviz!(ax_inset, scene.mtg; color=Dict("Cobblestone" => :gray87, "LeafSection" => "#42A25ABD", "Panel" => :black))
        f
    end
end