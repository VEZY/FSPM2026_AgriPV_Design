isdefined(@__MODULE__, :saved_day_plant_series) || include("daily_plotting.jl")
isdefined(@__MODULE__, :plot_assimilation_facets) || include("assimilation_plotting.jl")

day = Date(2025, 7, 2)
variable = :assimilation_step
df = saved_day_plant_series(; day, variable, config_ids=0:3)
df.hour = _agripv_plot_hours(df.datetime, day)
assimilation_plot = plot_assimilation_facets(df; x=:hour, y=variable,
    config=:config_id, plant=:plant_id, xlabel="Hour",
    ylabel="Net assimilation per step (μmol CO₂ plant⁻¹)",
    title="Net assimilation per plant per saved step — $day",
    axis=(; xticks=0:2:24, limits=((0, 24), nothing)))
f = assimilation_plot.figure
save(joinpath(_agripv_project_root(), "2_outputs", "day_step_assimilation_per_config.png"),
    f; px_per_unit=3.0)
f
