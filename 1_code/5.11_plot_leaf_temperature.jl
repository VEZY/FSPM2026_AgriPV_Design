# Read retained outputs only. Run through Kaimon with mt=true for GLMakie.
include("leaf_temperature_plotting.jl")
leaf_temperature_figures = plot_leaf_temperature_3d()
