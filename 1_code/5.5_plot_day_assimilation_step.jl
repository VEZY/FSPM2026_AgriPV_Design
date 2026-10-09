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
    figure_options = (;
        size=(900, 700),
        title = "Assimilation per plant per step for each config over a day",
        subtitle = """
            For the day July 2, 2025, with a plant density of 60 plants m⁻² and a GCR¹ of 40%.""",
        footnotes = ["¹Ground Coverage Ratio (GCR) is the ratio of the area covered by solar panels to the total ground area."],
    )

    aPPFD =
        data(df) *
        mapping(
            :datetime => (x -> DateTime(x)) => "Time",
            :assimilation_step => "Assimilation per plant per step (μmol plant⁻¹ hour⁻¹)",
            group = :plant_id,
            layout = :configID => (x -> "Config " * string(x))
        ) *
        visual(Lines, alpha=0.05, color=:black, label = "Individual plants", legend = (; alpha=0.5, linewidth = 1)) +

        data(df_mean) *
        mapping(
            :datetime => (x -> DateTime(x)) => "Time",
            :assimilation_step_mean => "Assimilation per plant per step (μmol plant⁻¹ hour⁻¹)",
            layout = :configID => (x -> "Config " * string(x))
        ) *
        visual(Lines, color=:red, linewidth=2, label = "Mean", legend = (; linewidth = 2))

    grid = draw(aPPFD; figure = figure_options, legend = (; visible = false))
    # axislegend(grid.grid[1, 1].axis, position = :lt)
    # grid.figure
end

save("2_outputs/day_step_assimilation_per_config.png", grid, update=false, px_per_unit=3.0)