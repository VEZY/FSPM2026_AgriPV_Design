using AlgebraOfGraphics, CairoMakie, CSV, DataFrames, Dates, TOML

"""
Read the STICS leaf-area growth target (`laimax`, m² m⁻²) and height
(`hauteur`, m) directly from the file consumed by ArchiCrop.

By default, retain exactly the dates of the saved wheat OBJ meshes. Pass
`archicrop_dir=nothing` to retain the active crop period instead. Green LAI
(`lai(n)`) is a different quantity: ArchiCrop handles senescence separately.
"""
function load_stics_growth_targets(;
    input_file=joinpath(@__DIR__, "..", "0_simulations", "stics", "wheat",
        "neodur_2025", "mod_sneodur_2025.sti"),
    archicrop_dir=joinpath(@__DIR__, "..", "2_outputs", "archicrop"),
    mesh_prefix="wheat")
    source = CSV.read(input_file, DataFrame; delim=';', stripwhitespace=true, ntasks=1)
    rename!(source, names(source) .=> strip.(names(source)))
    required = ["ian", "mo", "jo", "laimax", "hauteur", "laisen(n)"]
    all(name -> name in names(source), required) ||
        throw(ArgumentError("STICS output requires columns $required."))
    dates = Date.(Int.(source.ian), Int.(source.mo), Int.(source.jo))
    length(unique(dates)) == length(dates) ||
        throw(ArgumentError("Expected one STICS plant record per date."))
    targets = DataFrame(date=dates, lai_max=Float64.(source.laimax),
        height_m=Float64.(source.hauteur))
    all(row -> isfinite(row.lai_max) && row.lai_max >= 0 &&
        isfinite(row.height_m) && row.height_m >= 0, eachrow(targets)) ||
        throw(ArgumentError("STICS growth targets must be finite and nonnegative."))

    if isnothing(archicrop_dir)
        keep = (source.hauteur .> 0) .& (source[!, "laisen(n)"] .< source.laimax)
        targets = targets[keep, :]
    else
        mesh_dates = Date[]
        for filename in readdir(archicrop_dir)
            startswith(filename, mesh_prefix * "_") && endswith(filename, ".obj") || continue
            found = match(r"_(\d{4}-\d{2}-\d{2})\.obj$", filename)
            isnothing(found) || push!(mesh_dates, Date(found.captures[1]))
        end
        isempty(mesh_dates) && throw(ArgumentError("No saved $mesh_prefix OBJ dates in $archicrop_dir."))
        wanted = Set(mesh_dates)
        issubset(wanted, Set(dates)) ||
            throw(ArgumentError("Some ArchiCrop mesh dates are missing from STICS output."))
        targets = filter(:date => in(wanted), targets)
    end
    isempty(targets) && throw(ArgumentError("No STICS growth targets in the selected period."))
    sort!(targets, :date)
    targets.day = Dates.value.(targets.date .- first(targets.date))
    return targets
end

"""
Make a compact two-panel AoG/Makie inset with a shared calendar axis.
The two quantities retain their own units and zero baselines. Sparse endpoint
values replace dense ticks, and the coloured labels replace a legend.
"""
function plot_stics_growth_inset(targets; size=(240, 150), linewidth=2.8,
    fontsize=12, background=:transparent, show_values=true)
    colors = ("#3479B9", "#DA8919")
    foreground = "#24374C"
    first_day, last_day = extrema(targets.date)
    span = Dates.value(last_day - first_day)
    span > 0 || throw(ArgumentError("At least two distinct dates are required."))
    month_dates = collect(Date(year(first_day), month(first_day), 1):Month(1):last_day)
    # Keep at most three date labels so the inset stays legible when reduced.
    indices = unique(round.(Int, range(1, length(month_dates); length=min(3, length(month_dates)))))
    tick_dates = month_dates[indices]
    ticks = (Dates.value.(max.(tick_dates, first_day) .- first_day),
        Dates.format.(tick_dates, dateformat"u"))
    figure = Figure(; size, fontsize, backgroundcolor=background,
        figure_padding=(5, 8, 5, 5), fonts=(; regular="DejaVu Sans", bold="DejaVu Sans Bold"))
    axes = Axis[]
    for (i, (column, label)) in enumerate(((:lai_max, "LAImax"), (:height_m, "Height (m)")))
        maximum_value = maximum(targets[!, column])
        maximum_value > 0 || throw(ArgumentError("Cannot draw a zero-only $column growth curve."))
        upper_label = string(round(maximum_value; digits=2))
        axis = Axis(figure[i, 1];
            backgroundcolor=background, xlabel="", ylabel="", xticks=ticks,
            yticks=([0.0, maximum_value], ["0", upper_label]),
            xticklabelsize=fontsize - 1, yticklabelsize=fontsize - 1,
            xticklabelcolor=foreground, yticklabelcolor=foreground,
            xtickcolor=foreground, ytickcolor=foreground,
            xticksize=3, yticksize=3, xticklabelpad=3, yticklabelpad=3,
            xgridvisible=false, ygridvisible=false,
            topspinevisible=false, rightspinevisible=false,
            leftspinecolor=(foreground, 0.55), bottomspinecolor=(foreground, 0.55),
            spinewidth=0.8, yticklabelspace=28.0,
            limits=((-0.02span, 1.02span), (-0.025maximum_value, 1.18maximum_value)))
        layer = AlgebraOfGraphics.data(targets) *
            AlgebraOfGraphics.mapping(:day => "", column => "") *
            AlgebraOfGraphics.visual(Lines; color=colors[i], linewidth)
        AlgebraOfGraphics.draw!(axis, layer)
        text!(axis, 0.03span, 1.14maximum_value; text=label,
            color=colors[i], fontsize, font=:bold, align=(:left, :top))
        push!(axes, axis)
        i == 1 && hidexdecorations!(axis)
        if !show_values
            hideydecorations!(axis)
            hidespines!(axis, :l)
        end
    end
    linkxaxes!(axes...)
    rowgap!(figure.layout, 8)
    return figure
end

"""Export the inset and its exact daily source values, without running a model."""
function regenerate_stics_forcing_inset(;
    output_dir=joinpath(@__DIR__, "..", "2_outputs"), show_values=true,
    input_file=joinpath(@__DIR__, "..", "0_simulations", "stics", "wheat",
        "neodur_2025", "mod_sneodur_2025.sti"),
    archicrop_dir=joinpath(@__DIR__, "..", "2_outputs", "archicrop"), kwargs...)
    CairoMakie.activate!()
    targets = load_stics_growth_targets(; input_file, archicrop_dir)
    figure = plot_stics_growth_inset(targets; show_values, kwargs...)
    mkpath(output_dir)
    stem = joinpath(output_dir, "stics_forcing_inset")
    save(stem * ".png", figure; px_per_unit=4)
    save(stem * ".svg", figure)
    save(stem * ".pdf", figure)
    preview = plot_stics_growth_inset(targets; show_values, kwargs..., background=:white)
    save(stem * "_preview.png", preview; px_per_unit=1)
    CSV.write(stem * ".csv", select(targets, :date, :lai_max, :height_m))
    open(stem * ".toml", "w") do io
        TOML.print(io, Dict(
            "input_file" => relpath(abspath(input_file), abspath(output_dir)),
            "scope" => isnothing(archicrop_dir) ? "active STICS crop period" : "saved ArchiCrop mesh dates",
            "first_date" => string(first(targets.date)),
            "last_date" => string(last(targets.date)),
            "daily_records" => nrow(targets),
            "lai_max" => Dict("source_column" => "laimax", "unit" => "m2 leaf / m2 ground"),
            "height_m" => Dict("source_column" => "hauteur", "unit" => "m"),
            "note" => "Raw daily growth targets; green LAI lai(n) and separate senescence forcing are not plotted."))
    end
    return (; figure, targets, png=stem * ".png", svg=stem * ".svg", pdf=stem * ".pdf",
        preview=stem * "_preview.png")
end

if abspath(PROGRAM_FILE) == @__FILE__
    regenerate_stics_forcing_inset()
end
