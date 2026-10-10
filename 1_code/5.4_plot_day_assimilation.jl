isdefined(@__MODULE__, :saved_day_plant_series) || include("daily_plotting.jl")

day = Date(2025, 7, 2)
variable = :assimilation_cumulative
df = saved_day_plant_series(; day, variable, config_ids=0:3)
ylabel = "Cumulative net assimilation (μmol CO₂ plant⁻¹)"
f1 = plot_daily_plant_panels(df; day, variable, ylabel,
    title="Cumulative net assimilation per plant")
f2 = plot_daily_config_means(df; day, variable, ylabel,
    title="Mean cumulative net assimilation")
for (filename, figure) in (("day_cumulative_assimilation_per_config.png", f1),
    ("day_cumulative_assimilation_means.png", f2))
    save(joinpath(_agripv_project_root(), "2_outputs", filename), figure;
        px_per_unit=3.0)
end
f2
