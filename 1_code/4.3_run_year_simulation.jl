using Dates

# Reload the daily setup when rerunning this driver in an existing Julia session.
include("simulation.jl")
include("year_simulation.jl")

# Plant maquettes define the growing period. Their filenames must end in
# YYYY-MM-DD.obj, with a matching .mtg. Narrow the glob for another crop series.
plant_dir = joinpath(_agripv_project_root(), "2_outputs", "archicrop")
plant_pattern = "wheat_*.obj"
sources = plant_simulation_days(; plant_dir, plant_pattern)
days = getproperty.(sources, :day)
configIDs = 0:3
# Keep the STICS density explicit, as in 4.2_run_day_simulation.jl.
stics_density = 268.0 # plants m⁻²
scene_kwargs = (; plant_density=stics_density)

# Read the climate once for all configurations; each daily solve gets only
# its date's forcing and reconstructs that date's plant geometry.
meteo = get_meteo(days)

for configID in configIDs
    summary = year_simulation(; pvconfig=get_pvconfig(configID), config_id=configID,
        plant_dir, plant_pattern, meteo, scene_kwargs, storage=:parquet,
        compression_level=19, seed=20261009 + 1_000_003 * configID)
    @info "Growth-period outputs saved" configID days=length(summary.days) paths=summary.paths
end
println(now(), " Finished running year simulations for all configurations.")
