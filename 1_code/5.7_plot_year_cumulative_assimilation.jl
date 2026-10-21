using CSV, Dates, DataFrames, AlgebraOfGraphics, GLMakie

isdefined(@__MODULE__, :summarize_year_assimilation) || include("yearly_assimilation_plotting.jl")
isdefined(@__MODULE__, :plot_assimilation_facets) || include("assimilation_plotting.jl")

year_assimilation_root = normpath(joinpath(@__DIR__, ".."))
meteo = CSV.read(joinpath(year_assimilation_root, "0_simulations", "meteo",
    "meteo_data_2025_montpellier.csv"), DataFrame)

# Every planting instance is included. Integrate all signed hourly steps, then
# render each day's endpoint (121 vertices per plant for the complete cycle).
# The underlying saved-output summary remains in μmol CO₂; plotting uses mol.
configIDs = collect(0:3)
individual = DataFrame[]
whole_crop = DataFrame[]
for config_id in configIDs
    @info "Integrating yearly assimilation from saved outputs" config_id
    summary = summarize_year_assimilation(; config_id, curve_sampling=:daily)
    push!(individual, summary.individual)
    push!(whole_crop, summary.whole_crop)
end
df = vcat(individual...)
df_sum = vcat(whole_crop...)
df.assimilation_cumulative_mol = df.assimilation_cumulative ./ 1e6

year_assimilation_plot = plot_assimilation_facets(df;
    x=:datetime, y=:assimilation_cumulative_mol, config=:configID,
    plant=:plant_instance_id, xlabel="Day", ylabel="Cumulative assimilation (mol CO₂ plant⁻¹)",
    title="Growth-cycle cumulative assimilation per plant",
    footer="Daily endpoints; all hourly assimilation steps integrated.")
f1 = year_assimilation_plot.figure
save(joinpath(year_assimilation_root, "2_outputs", "year_cumulative_assimilation_per_plant.png"),
    f1, px_per_unit=3.0)


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
save(joinpath(year_assimilation_root, "2_outputs", "year_cumulative_assimilation_total.png"),
    f2, px_per_unit=3.0)
