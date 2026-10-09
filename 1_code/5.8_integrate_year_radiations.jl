# Historical filename: this script integrates net carbon assimilation, not radiation.
using CSV, DataFrames
isdefined(@__MODULE__, :integrated_plant_assimilation) || include("attach_assimilation_to_scene.jl")

config_id = 0
# DuckDB aggregates on disk; only one row per plant is materialized.
df_integrated = integrated_plant_assimilation(; config_id)
summary_dir = joinpath(_agripv_project_root(), "2_outputs", "cumulative_assimilation")
mkpath(summary_dir)
CSV.write(joinpath(summary_dir, "integrated_plants_config_$(config_id).csv"), df_integrated)
