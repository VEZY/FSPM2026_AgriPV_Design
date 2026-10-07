using Glob, CSV
using Dates, DataFrames
using AlgebraOfGraphics
using GLMakie
using Statistics, DataFramesMeta

sources = glob("2_outputs/simulations/daily/plants_*.csv")
regex = r"plants_config_(\d+)_(\d+-\d+-\d+)"
configIDs = []
dates = []
for src in sources
    m = match(regex, src)
    push!(configIDs, parse(Int, m.captures[1]))
    push!(dates, Date(m.captures[2]))
end
df = CSV.read(sources, DataFrame; source=:configID => configIDs)

# Compute mean per configID and datetime
df_mean = @chain df begin
    groupby([:configID, :datetime])
    @combine :assimilation_step_mean = mean(coalesce.(:assimilation_step, 0.0))
end

f = Figure(size=(900, 700))#, title="Absorbed PAR for each config over a day", xlabel="Time of day", ylabel="A (μmol plant⁻¹ hour⁻¹)")

# ax = Axis(f[1, 1], title="Config")
# for configID in configIDs
#     row = 1 + (configID) ÷ 2
#     col = 1 + (configID) % 2
#     ax = Axis(f[row, col], title="Config $configID")
    
#     aPPFD =
#         data(filter(:configID => ==(configID), df)) *
#         mapping(
#             # :datetime => (x -> DateTime(x)) => "Time",
#             :timestep => "Timestep",
#             :assimilation_cumulative => "Assimilation",
#             color = :plant_id
#         ) *
#         visual(Lines, alpha=0.05)

#     draw!(ax, aPPFD)
# end
    
aPPFD =
    data(df) *
    mapping(
        :datetime => (x -> DateTime(x)) => "Time",
        :assimilation_step => "Assimilation per step per plant (μmol plant⁻¹ hour⁻¹)",
        group = :plant_id,
        layout = :configID
    ) *
    visual(Lines, alpha=0.05) +

    data(df_mean) *
    mapping(
        :datetime => (x -> DateTime(x)) => "Time",
        :assimilation_step_mean => "Assimilation per step per plant (μmol plant⁻¹ hour⁻¹)",
        layout = :configID
    ) *
    visual(Lines, color=:red, linewidth=2)

draw!(f, aPPFD)
save("2_outputs/day_step_assimilation_per_config.png", f, update=false, px_per_unit=3.0)