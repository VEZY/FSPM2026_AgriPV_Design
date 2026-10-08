using Dates

include("year_simulation.jl")

# Plant maquettes define the growing period. Their filenames must end in
# YYYY-MM-DD.obj, with a matching .mtg. Narrow the glob for another crop series.
plant_dir = joinpath(_agripv_project_root(), "2_outputs", "archicrop")
plant_pattern = "wheat_*.obj"
sources = plant_simulation_days(; plant_dir, plant_pattern)
days = getproperty.(sources, :day)
configIDs = 0:3

# Read the climate once for all configurations; each daily solve gets only
# its date's forcing and reconstructs that date's plant geometry.
meteo = get_meteo(days)

# Started at 2026-10-07T16:35:00. Running year simulations for configurations 1:3.
for configID in configIDs
    summary = year_simulation(; pvconfig=get_pvconfig(configID), config_id=configID,
        plant_dir, plant_pattern, meteo)
    @info "Growth-period outputs saved" configID days=length(summary.days) paths=summary.paths
end
println(now(), " Finished running year simulations for all configurations.")
# 2026-10-07T21:58:34.936