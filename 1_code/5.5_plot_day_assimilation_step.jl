isdefined(@__MODULE__, :saved_day_plant_series) || include("daily_plotting.jl")

day = Date(2025, 7, 2)
variable = :assimilation_step
df = saved_day_plant_series(; day, variable, config_ids=0:3)
f = plot_daily_plant_panels(df; day, variable,
    ylabel="Net assimilation per step (μmol CO₂ plant⁻¹)",
    title="Net assimilation per plant per saved step")
save(joinpath(_agripv_project_root(), "2_outputs", "day_step_assimilation_per_config.png"),
    f; px_per_unit=3.0)
f
