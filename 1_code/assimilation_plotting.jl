using AlgebraOfGraphics, DataFrames, Dates, Statistics, GLMakie

function _assimilation_facet_tables(table; x::Symbol, y::Symbol, config::Symbol, plant::Symbol)
    required = (x, y, config, plant)
    length(unique(required)) == 4 || throw(ArgumentError("Select distinct x, y, configuration and plant columns."))
    all(column -> column in propertynames(table), required) ||
        throw(ArgumentError("Assimilation plotting requires columns $required."))
    isempty(table) && throw(ArgumentError("No saved plant assimilation to plot."))
    individuals = DataFrames.select(table, x => :plot_x, y => :value,
        config => :config_id, plant => :plant_id)
    all(row -> !ismissing(row.config_id) && !ismissing(row.plant_id) &&
        (row.plot_x isa Dates.TimeType || (row.plot_x isa Real && isfinite(row.plot_x))) &&
        row.value isa Real && isfinite(row.value), eachrow(individuals)) ||
        throw(ArgumentError("Plant identities and x values must be present; assimilation must be finite."))
    nrow(unique(individuals[:, [:config_id, :plant_id, :plot_x]])) == nrow(individuals) ||
        throw(ArgumentError("Repeated plant assimilation at a configuration and timestamp."))
    for configuration in groupby(individuals, :config_id)
        snapshots = groupby(configuration, :plot_x)
        reference = Set(first(snapshots).plant_id)
        all(snapshot -> Set(snapshot.plant_id) == reference, snapshots) ||
            throw(ArgumentError("Plant coverage changes within an assimilation configuration."))
    end
    sort!(individuals, [:config_id, :plant_id, :plot_x])
    means = sort!(combine(groupby(individuals, [:config_id, :plot_x]),
        :value => mean => :value_mean), [:config_id, :plot_x])
    individuals.config_label = ["Config $id" for id in individuals.config_id]
    means.config_label = ["Config $id" for id in means.config_id]
    return (; individuals, means)
end

"""
    plot_assimilation_facets(table; x, y, config, plant, xlabel, ylabel, title, ...)

Plot every plant as a translucent black line and each configuration's complete
plant mean as a red line. Configuration facets wrap into two columns and share
all x and y scales. Tick decorations remain on the outside; x/y labels and the
optional two-entry legend appear once for the complete figure.
`footer` optionally adds a short figure footnote describing temporal sampling.
`column_gap` sets the space between facets; by default calendar axes receive
more space than numeric hour axes so their longer tick labels remain distinct.

`plant` must identify a persistent planting position over the supplied x range.
Data are sorted by configuration, plant and x before connecting curves. Missing,
nonfinite, duplicate and incomplete plant series are rejected; signed values
are retained. Numeric hours and Date/DateTime x values are supported.

Return `(; figure, grid, means, individuals)`, where `grid` is AoG's FigureGrid.
Save `result.figure`. `axis` forwards a NamedTuple of common Makie axis options,
for example daily `axis=(; xticks=0:2:24, limits=((0, 24), nothing))`.
Run through Kaimon with `mt=true` for GLMakie.
"""
function plot_assimilation_facets(table; x::Symbol, y::Symbol, config::Symbol, plant::Symbol,
    xlabel::String, ylabel::String, title::String,
    individual_alpha=0.035, mean_alpha=1.0, individual_linewidth=1.0,
    mean_linewidth=2.5, size=(1100, 760), show_legend=true, axis=(;),
    footer::Union{Nothing,String}=nothing, column_gap=nothing)
    all(value -> value isa Real && isfinite(value) && 0 <= value <= 1,
        (individual_alpha, mean_alpha)) || throw(ArgumentError("Line alpha must lie between zero and one."))
    all(value -> value isa Real && isfinite(value) && value > 0,
        (individual_linewidth, mean_linewidth)) || throw(ArgumentError("Line widths must be positive and finite."))
    tables = _assimilation_facet_tables(table; x, y, config, plant)
    gap = isnothing(column_gap) ?
        (first(tables.individuals.plot_x) isa Dates.TimeType ? 72.0 : 48.0) : column_gap
    gap isa Real && isfinite(gap) && gap >= 0 ||
        throw(ArgumentError("Column gap must be nonnegative and finite."))
    individual_layer = AlgebraOfGraphics.data(tables.individuals) *
        AlgebraOfGraphics.mapping(:plot_x => xlabel, :value => ylabel;
            group=:plant_id => AlgebraOfGraphics.nonnumeric, layout=:config_label) *
        AlgebraOfGraphics.visual(Lines; color=:black, alpha=individual_alpha,
            linewidth=individual_linewidth, label="Individual plants",
            legend=(; alpha=0.5, linewidth=1.5))
    mean_layer = AlgebraOfGraphics.data(tables.means) *
        AlgebraOfGraphics.mapping(:plot_x => xlabel, :value_mean => ylabel;
            layout=:config_label) *
        AlgebraOfGraphics.visual(Lines; color=:red, alpha=mean_alpha,
            linewidth=mean_linewidth, label="Mean")
    grid = AlgebraOfGraphics.draw(individual_layer + mean_layer,
        AlgebraOfGraphics.scales(Layout=(; palette=AlgebraOfGraphics.wrapped(cols=2)));
        axis, figure=(; size, title, titlesize=24, titlealign=:center, fontsize=18,
            footnotes=isnothing(footer) ? nothing : Any[footer], footnotesize=16,
            footnotealign=:center),
        facet=(; linkxaxes=:all, linkyaxes=:all, hidexdecorations=true,
            hideydecorations=true, singlexlabel=true, singleylabel=true),
        legend=(; show=show_legend, position=:bottom, orientation=:horizontal,
            framevisible=false))
    colgap!(grid.figure.layout, gap)
    return (; figure=grid.figure, grid, tables.means, tables.individuals)
end
