# Execute through Kaimon with mt=true for GLMakie.
# These tests write synthetic saved tables and exercise plotting readers and
# aggregation contracts. They do not run radiation or physiology simulations.
include("daily_plotting.jl")
include("year_fapar.jl")
include("integrated_outputs.jl")
include("assimilation_plotting.jl")
include("yearly_assimilation_plotting.jl")
include("scene_orientation.jl")
