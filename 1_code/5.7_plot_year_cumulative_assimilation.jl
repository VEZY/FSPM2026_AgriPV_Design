using Glob, CSV
using Dates, DataFrames
using AlgebraOfGraphics
using GLMakie
using Statistics, DataFramesMeta

meteo = CSV.read("0_simulations/meteo/meteo_data_2025_montpellier.csv", DataFrame)

sources = glob("2_outputs/simulations/yearly/plants_*.csv")
regex = r"plants_config_(\d+)"
configIDs = []
dates = []
for src in sources
    m = match(regex, src)
    push!(configIDs, parse(Int, m.captures[1]))
end
df = CSV.read(sources, DataFrame; source=:configID => configIDs)
sort!(df, :plant_id)
n_unique_plant_ids = length(unique(df.plant_id))
println("Number of different plant_id: ", n_unique_plant_ids)

# Transform the cumulative assimilation to be on the year period, per plant per config
df = @chain df begin
    groupby([:configID, :plant_id])
    @transform :assimilation_cumulative = cumsum(:assimilation_step)
end

# Compute mean per configID and datetime
df_sum = @chain df begin
    groupby([:configID, :datetime])
    @combine :assimilation_cumulative_sum = sum(coalesce.(:assimilation_cumulative, 0.0))
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
    
selected_day = Date(2025, 7, 2) # Change this to the day you want to display
day_start = DateTime(selected_day)
day_end = DateTime(selected_day + Day(1))
df_day = filter(:datetime => x -> day_start <= DateTime(x) < day_end, df)
df_day_plant = filter(:plant_id => ==(3), df_day)
df_plant = filter(:plant_id => ==(59391), df)

begin
    f1 = Figure(size=(900, 700))#, title="Absorbed PAR for each config over a day", xlabel="Time of day", ylabel="A (μmol plant⁻¹ hour⁻¹)")

    aPPFD =
        data(df_plant) *
        mapping(
            :datetime => (x -> DateTime(x)) => "Time",
            # :timestep => "Timestep",
            :assimilation_cumulative => "Cumulative assimilation per plant",
            group = :plant_id,
            layout = :configID
        ) *
        visual(Lines, alpha=0.5)

    draw!(f1, aPPFD)
    f1
end
save("2_outputs/year_cumulative_assimilation_per_plant.png", f1, update=false, px_per_unit=3.0)

begin
    f2 = Figure(size=(900, 700))

    assim_cumul_sum =
        data(df_sum) *
        mapping(
            :datetime => (x -> DateTime(x)) => "Time",
            :assimilation_cumulative_sum => "Cumulative assimilation over the day (μmol)",
            color = :configID => (x -> "Config " * string(x)) => "PV configurations",
            group = :configID
        ) *
        visual(Lines, linewidth=2)

    # draw(assim_cumul_sum)
    grid = draw!(f2[1,1], assim_cumul_sum)
    legend!(f2[1,1], grid; tellheight=false, tellwidth=false, halign=:left, valign=:top)

    meteo_relative_humidity = DataFrame(
        datetime = DateTime.(meteo.date),
        relative_humidity = meteo.Rh
    )
    assim_start = minimum(df_sum.datetime)
    assim_end = maximum(df_sum.datetime)
    filter!(:datetime => t -> assim_start <= t <= assim_end, meteo_relative_humidity)

    meteo_overlay =
        data(meteo_relative_humidity) *
        mapping(
            :datetime => "Time",
            :relative_humidity => "Relative Humidity (%)"
        ) *
        visual(Lines, linewidth=1.5)

    draw!(f2[1,1], meteo_overlay)
    # axislegend(f2[1,1]; position=:rt)
    f2
end
save("2_outputs/year_cumulative_assimilation_total.png", f2, update=false, px_per_unit=3.0)