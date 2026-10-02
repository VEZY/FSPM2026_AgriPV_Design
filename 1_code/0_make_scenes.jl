using Dates
using PlantGeom

include("scene.jl")

configIDs = [Int8(x) for x in range(0, 89)]
days = Date(2025, 3, 4):Day(1):Date(2025, 7, 2) |> collect

for configID in configIDs
    config = get_pvconfig(configID)

    for day in days
        println("Making scene for config $configID day $day")

        @time scene = agripv_scene(
            plant_density=60,
            n_rows=5,
            c=config,
            day=day
        )

        @time write_ops("2_outputs/scenes/config$(configID)_$day.ops", scene.mtg)
    end
end