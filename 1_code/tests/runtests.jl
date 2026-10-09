# Execute via Kaimon in the coutellier_agripv project.
include("meteo.jl")
include("plant_balance.jl")
include("simulation_outputs.jl")
include("mtg_outputs.jl")
include("scene.jl")
include("geometry_selector.jl")
include("saved_simulation.jl")
include("fvcb.jl")
include("year_simulation.jl")
include("year_fapar.jl")

include("parquet_output_io.jl")
# The temporary local repair runner is intentionally not tracked with the repo.
if isfile(joinpath(@__DIR__, "..", "..", "2_outputs", "overnight_scripts", "run_missing_outputs.jl"))
    include("missing_output_repair.jl")
end
