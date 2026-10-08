using GLMakie, Dates, DataFrames

"""Plot daily energy ratios for each PV configuration; GLMakie needs `mt=true`."""
function plot_year_fapar(daily; output_path=joinpath(@__DIR__, "..", "2_outputs",
    "faPAR_over_time_plants_panels_ground.png"))
    isempty(daily) && throw(ArgumentError("No daily faPAR values to plot."))
    configs = sort(unique(daily.config_id))
    first_day, last_day = extrema(daily.day)
    ticks = sort!(unique([first_day; collect(firstdayofmonth(first_day) + Month(1):Month(1):last_day)]))
    if last_day > last(ticks) && (length(ticks) == 1 || last_day - last(ticks) > Day(10))
        push!(ticks, last_day)
    end
    tick_positions = Dates.value.(ticks .- first_day)
    tick_labels = Dates.format.(ticks, "dd u")
    colors = (:forestgreen, :steelblue, :sienna, :black)
    groups = (:plants, :panels, :ground, :total)
    ncols = min(2, length(configs))
    nrows = cld(length(configs), ncols)
    figure = Figure(size=(650*ncols, 370*nrows + 110), fontsize=17)
    Label(figure[0, 1:ncols], "Daily fraction of sky PAR absorbed", fontsize=24)
    axes = Axis[]
    finite_totals = collect(skipmissing(daily.fapar_total))
    ymax = isempty(finite_totals) ? 1.05 : max(1.05, maximum(finite_totals) * 1.03)
    for (index, config) in enumerate(configs)
        row, col = fldmod1(index, ncols)
        axis = Axis(figure[row, col]; title="Configuration $config",
            xlabel="Date ($(year(first_day)))", ylabel="faPAR",
            xticks=(tick_positions, tick_labels))
        table = sort(filter(:config_id => ==(config), daily), :day)
        x = Dates.value.(table.day .- first_day)
        hlines!(axis, [1.0]; color=(:gray, 0.6), linestyle=:dot, linewidth=1.5)
        for (group, color) in zip(groups, colors)
            values = [ismissing(value) ? NaN : Float64(value) for value in table[!, Symbol("fapar_$group")]]
            lines!(axis, x, values; color, linewidth=group == :total ? 2.0 : 2.5,
                linestyle=group == :total ? :dash : :solid)
        end
        ylims!(axis, 0, ymax)
        push!(axes, axis)
    end
    elements = [LineElement(; color, linewidth=2.5, linestyle=group == :total ? :dash : :solid)
        for (group, color) in zip(groups, colors)]
    Legend(figure[nrows + 1, 1:ncols], elements, ["Plants", "Solar panels", "Ground", "Total"];
        orientation=:horizontal, tellheight=true)
    mkpath(dirname(abspath(output_path)))
    save(output_path, figure; px_per_unit=2)
    return (; figure, axes, output_path=abspath(output_path))
end
