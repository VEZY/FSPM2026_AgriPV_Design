using CSV, DataFrames
using GLMakie

df = CSV.read("2_outputs/simulations/yearly/config_summary.csv", DataFrame)
sort!(df, :config_id)

config_positions = collect(eachindex(df.config_id))
bar_width = 0.36

begin
    fig = Figure(size=(900, 600))
    assimilation_axis = Axis(
        fig[1, 1],
        xlabel="Configuration ID",
        ylabel="Mean assimilation per plant (mol CO₂)",
        limits=(nothing, (0.1, 0.2)),
    )
    transpiration_axis = Axis(
        fig[1, 1],
        yaxisposition=:right,
        ylabel="Mean transpiration per plant (kg H₂O)",
        limits=(nothing, (1, 2)),
        backgroundcolor=:transparent,
        xaxisposition=:top,
        xticklabelsvisible=false,
        xticksvisible=false,
        xlabelvisible=false,
        xgridvisible=false,
        ygridvisible=false,
    )
    linkxaxes!(assimilation_axis, transpiration_axis)

    assimilation_bars = barplot!(
        assimilation_axis,
        config_positions .- bar_width / 2,
        df.total_assimilation_mean_per_plant ./ 1e6;
        width=bar_width,
        color=:darkorange,
    )
    transpiration_bars = barplot!(
        transpiration_axis,
        config_positions .+ bar_width / 2,
        df.total_transpiration_mean_per_plant;
        width=bar_width,
        color=:steelblue,
    )

    assimilation_axis.xticks = (config_positions, string.(df.config_id))
    xlims!(assimilation_axis, 0.5, length(config_positions) + 0.5)
    axislegend(
        assimilation_axis,
        [assimilation_bars, transpiration_bars],
        ["Mean assimilation per plant", "Mean transpiration per plant"],
        position=:lt,
    )

    fig
end

save("2_outputs/plots/yearly_summary.png", fig)