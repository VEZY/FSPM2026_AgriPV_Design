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
df_sum = @chain df begin
    groupby([:configID, :datetime])
    @combine :assimilation_cumulative_mean = sum(coalesce.(:assimilation_cumulative, 0.0))
end

f1 = Figure(size=(900, 700))#, title="Absorbed PAR for each config over a day", xlabel="Time of day", ylabel="A (μmol plant⁻¹ hour⁻¹)")

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
        # :timestep => "Timestep",
        :assimilation_cumulative => "Cumulative assimilation per plant",
        group = :plant_id,
        layout = :configID
    ) *
    visual(Lines, alpha=0.05)

draw!(f1, aPPFD)
save("2_outputs/day_cumulative_assimilation_per_config.png", f1, update=false, px_per_unit=3.0)

f2 = Figure(size=(900, 700))

assim_cumul_sum =
    data(df_sum) *
    mapping(
        :datetime => (x -> DateTime(x)) => "Time",
        :assimilation_cumulative_mean => "Cumulative assimilation over the day (μmol)",
        color = :configID => (x -> "Config " * string(x)) => "PV configurations",
        group = :configID
    ) *
    visual(Lines, linewidth=2)

# draw(assim_cumul_sum)
grid = draw!(f2[1,1], assim_cumul_sum)
legend!(f2[1,1], grid; tellheight=false, tellwidth=false, halign=:left, valign=:top)
save("2_outputs/day_cumulative_assimilation_total.png", f2, update=false, px_per_unit=3.0)