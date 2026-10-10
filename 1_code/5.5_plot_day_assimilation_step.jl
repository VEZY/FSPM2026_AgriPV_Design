isdefined(@__MODULE__, :saved_day_plant_series) || include("daily_plotting.jl")

# Set agripv_daily_plot_day before including this entry point to select another
# retained date, or call plot_saved_day_assimilation(; day, variable) directly.
day = isdefined(@__MODULE__, :agripv_daily_plot_day) ?
    Date(agripv_daily_plot_day) : Date(2025, 5, 15)
day_step_assimilation_plots = plot_saved_day_assimilation(;
    day, variable=:assimilation_step)
