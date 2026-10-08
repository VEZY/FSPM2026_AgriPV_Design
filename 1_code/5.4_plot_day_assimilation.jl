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
    @combine :assimilation_cumulative_mean = mean(coalesce.(:assimilation_cumulative, 0.0))
end

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

begin
    f1 = Figure(size=(900, 700))#, title="Absorbed PAR for each config over a day", xlabel="Time of day", ylabel="A (μmol plant⁻¹ hour⁻¹)")
    
    plt_cumul_assim =
        data(df) *
        mapping(
            :datetime => (x -> DateTime(x)) => "Time",
            # :timestep => "Timestep",
            :assimilation_cumulative => "Cumulative assimilation per plant (μmol plant⁻¹)",
            group = :plant_id,
            layout = :configID => (x -> "Config " * string(x))
        ) *
        visual(Lines, alpha=0.05) +

        data(df_mean) *
        mapping(
            :datetime => (x -> DateTime(x)) => "Time",
            :assimilation_cumulative_mean => "Cumulative assimilation per plant (μmol plant⁻¹)",
            layout = :configID => (x -> "Config " * string(x))
        ) *
        visual(Lines, color=:red, linewidth=2)

    draw!(f1, plt_cumul_assim)
    f1
end
save("2_outputs/day_cumulative_assimilation_per_config.png", f1, update=false, px_per_unit=3.0)

begin
    f2 = Figure(size=(900, 700))

    plt_means_cumul_assim =
        data(df_mean) *
        mapping(
            :datetime => (x -> DateTime(x)) => "Time",
            :assimilation_cumulative_mean => "Cumulative assimilation per plant (μmol plant⁻¹)",
            color = :configID => (x -> "Config " * string(x)) => "PV configurations",
            group = :configID
        ) *
        visual(Lines, linewidth=2)

    # draw(plt_means_cumul_assim)
    grid = draw!(f2[1,1], plt_means_cumul_assim)
    legend!(f2[1,1], grid; tellheight=false, tellwidth=false, halign=:left, valign=:top)
    f2
end
save("2_outputs/day_cumulative_assimilation_means.png", f2, update=false, px_per_unit=3.0)