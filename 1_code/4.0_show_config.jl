# Execute through Kaimon with mt=true for GLMakie.
# Rebuild retained geometry only; no radiation or physiology is simulated.
include("configuration_plotting.jl")

configuration_figures = plot_configurations()
