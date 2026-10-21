# Complete-period carbon, radiation and water tables from retained outputs only.
# Step totals are summed once; powers and rates use saved timestep durations.
isdefined(@__MODULE__, :write_period_summary_tables) || include("period_summary.jl")
period_summary_tables = write_period_summary_tables()
