isdefined(@__MODULE__, :saved_day_absorbed_par) || include("daily_plotting.jl")

day = Date(2025, 7, 2)
# Preserve the original per-step energy quantity using retained forcing durations.
df = saved_day_absorbed_par(; day, config_ids=0:3, quantity=:energy)
f = plot_daily_plant_panels(df; day, variable=:absorbed_PAR_J,
    ylabel="Absorbed PAR per step (J plant⁻¹)", title="Absorbed PAR energy per plant")
save(joinpath(_agripv_project_root(), "2_outputs", "day_aPAR_configs.png"),
    f; px_per_unit=3.0)
f
