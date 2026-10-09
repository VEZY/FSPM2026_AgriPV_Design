using Glob, CSV
using Dates, DataFrames
using AlgebraOfGraphics
using GLMakie
using Statistics, DataFramesMeta

meteo = CSV.read("0_simulations/meteo/meteo_data_2025_montpellier.csv", DataFrame)

isdefined(@__MODULE__, :with_saved_outputs) || include("parquet_output_io.jl")
# Query the complete cycle in DuckDB. Materialize only three plants per config
# for individual curves, plus one crop-total value per timestamp.
configIDs = collect(0:3)
individual = DataFrame[]
whole_crop = DataFrame[]
for config_id in configIDs
    with_saved_outputs(; config_id, tables=:plants) do con, metadata
        push!(individual, DataFrame(DBInterface.execute(con, """
            SELECT $config_id AS configID, plant_instance_id, datetime,
                sum(assimilation_step) OVER (
                    PARTITION BY plant_instance_id ORDER BY datetime
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS assimilation_cumulative
            FROM plants WHERE plant_instance_id IN (
                SELECT DISTINCT plant_instance_id FROM plants
                WHERE plant_instance_id IS NOT NULL ORDER BY plant_instance_id LIMIT 3)
            ORDER BY plant_instance_id, datetime
            """)))
        push!(whole_crop, DataFrame(DBInterface.execute(con, """
            SELECT $config_id AS configID, datetime,
                sum(step_sum) OVER (ORDER BY datetime
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS assimilation_cumulative_sum
            FROM (SELECT datetime, sum(assimilation_step) AS step_sum
                  FROM plants GROUP BY datetime) ORDER BY datetime
            """)))
    end
end
df = vcat(individual...)
df_sum = vcat(whole_crop...)

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
    
selected_plant_ids = unique(filter(:configID => ==(0), df).plant_instance_id)

begin
    f1 = Figure(size=(900, 700))
    ax = Axis(
        f1[1, 1],
        xlabel = "Time",
        ylabel = "Cumulative assimilation per plant",
        title = "Selected plants, Config 0"
    )

    for plantID in selected_plant_ids
        df_plant = filter(row -> row.plant_instance_id == plantID && row.configID == 0, df)
        lines!(
            ax,
            DateTime.(df_plant.datetime),
            df_plant.assimilation_cumulative;
            label = "plant_instance_id = $plantID"
        )
    end

    axislegend(ax; position = :rt)
    f1
end


# Three representative planting positions per config, integrated over the whole cycle
begin
    f1 = Figure(size=(900, 700))#, title="Absorbed PAR for each config over a day", xlabel="Time of day", ylabel="A (μmol plant⁻¹ hour⁻¹)")

    df_0 = filter(:configID => ==(0), df)
    df_1 = filter(:configID => ==(1), df)
    df_2 = filter(:configID => ==(2), df)
    df_3 = filter(:configID => ==(3), df)

    for (i, (configID, config_df)) in enumerate((0 => df_0, 1 => df_1, 2 => df_2, 3 => df_3))
        row = (i - 1) ÷ 2 + 1
        col = (i - 1) % 2 + 1
        aPPFD =
            data(config_df) *
            mapping(
                :datetime => (x -> DateTime(x)) => "Time",
                # :timestep => "Timestep",
                :assimilation_cumulative => "Cumulative assimilation (μmol CO₂/plant)",
                group = :plant_instance_id
            ) *
            visual(Lines, alpha=0.05)

        draw!(f1[row, col], aPPFD; axis=(title="Config $configID",))
    end
    f1
end
save("2_outputs/year_cumulative_assimilation_per_plant.png", f1, update=false, px_per_unit=3.0)



# Whole-crop sums, with weather in a separate panel because the units differ
begin
    f2 = Figure(size=(900, 900))

    assim_cumul_sum =
        data(df_sum) *
        mapping(
            :datetime => (x -> DateTime(x)) => "Time",
            :assimilation_cumulative_sum => "Growth-cycle cumulative assimilation (μmol CO₂)",
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
            :relative_humidity => "Relative humidity (fraction)"
        ) *
        visual(Lines, linewidth=1.5)

    draw!(f2[2,1], meteo_overlay)
    # axislegend(f2[1,1]; position=:rt)
    f2
end
save("2_outputs/year_cumulative_assimilation_total.png", f2, update=false, px_per_unit=3.0)
