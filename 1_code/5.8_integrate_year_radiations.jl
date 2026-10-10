# Integrate retained radiation and net carbon assimilation; no simulation is run.
using CSV, DataFrames
isdefined(@__MODULE__, :integrated_plant_assimilation) || include("attach_assimilation_to_scene.jl")

# DuckDB aggregates on disk; only one row per planting position is materialized.
integrated_outputs = write_integrated_plant_outputs()
summary_dir = joinpath(_agripv_project_root(), "2_outputs", "cumulative_assimilation")
mkpath(summary_dir)
for (config_id, table) in integrated_outputs
    df_integrated = DataFrame(plant_instance_id=table.plant_instance_id,
        total_assimilation=table.net_assimilation_mol_CO2_plant)
    CSV.write(joinpath(summary_dir, "integrated_plants_config_$(config_id).csv"), df_integrated)
end
