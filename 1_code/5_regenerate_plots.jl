# Run through Kaimon with mt=true for GLMakie.
# This entry point only reads retained simulation outputs and writes derived
# summaries and figures. No simulation driver is included.
using Dates

function _saved_plot_module(scripts; variables=(;))
    workspace = Module(gensym(:SavedPlots))
    Core.eval(workspace, :(include(path) = Base.include(@__MODULE__, path)))
    for (name, value) in pairs(variables)
        Core.eval(workspace, Expr(:(=), name, QuoteNode(value)))
    end
    for script in scripts
        @info "Regenerating figure from saved outputs" script
        Base.include(workspace, joinpath(@__DIR__, script))
    end
    return workspace
end

"""
    regenerate_saved_plots(; groups=(:configurations, :daily, :fapar, :assimilation,
        :integrated, :period_summary), assimilation_day=Date(2025, 5, 15))

Regenerate the numbered figures from retained outputs, through Kaimon with
`mt=true`. Configuration views include translucent periodic copies and use the
last common saved date, with geographic South down in the top views. Daily
assimilation figures use `assimilation_day`; other daily figures use the saved
2 July snapshot of the yearly run.
The integrated group rebuilds its small CSV summaries before rendering the
three cumulative quantities, each with and without panels, and the historical
configuration-0 assimilation view. The period-summary group exports one table
per configuration and a comparison table, with actual planting counts and
explicit units and aggregation formulas. Source simulation outputs are unchanged.
Select a subset of groups to rerun specific figures. Return the groups that
finished successfully; missing outputs and inconsistent identities raise errors.
"""
function regenerate_saved_plots(; groups=(:configurations, :daily, :fapar, :assimilation,
    :integrated, :period_summary), assimilation_day=Date(2025, 5, 15))
    groups = groups isa Symbol ? (groups,) : Tuple(groups)
    length(unique(groups)) == length(groups) || throw(ArgumentError("Repeated plotting groups."))
    all(group -> group in (:configurations, :daily, :fapar, :assimilation, :integrated, :period_summary), groups) ||
        throw(ArgumentError("Select :configurations, :daily, :fapar, :assimilation, :integrated or :period_summary."))
    completed = Symbol[]
    for group in groups
        scripts = if group == :configurations
            ("4.0_show_config.jl",)
        elseif group == :daily
            ("5.1_plot_static_simulation.jl", "5.2_plot_day_simulation.jl",
                "5.3_plot_day_apar.jl", "5.4_plot_day_assimilation.jl",
                "5.5_plot_day_assimilation_step.jl")
        elseif group == :fapar
            ("5.6_plot_year_fapar.jl",)
        elseif group == :assimilation
            ("5.7_plot_year_cumulative_assimilation.jl",)
        elseif group == :period_summary
            ("5.10_summarize_period.jl",)
        else
            ("5.8_integrate_year_radiations.jl", "5.8_plot_cumulative_appfd_3d.jl")
        end
        variables = group == :daily ? (; agripv_daily_plot_day=Date(assimilation_day)) : (;)
        workspace = _saved_plot_module(scripts; variables)
        if group == :integrated
            render = Base.invokelatest(getproperty, workspace, :plot_cumulative_appfd_3d)
            first_plot = Base.invokelatest(render)
            prepared = first_plot.scenes
            first_plot = nothing
            Core.eval(workspace, :(GLMakie.closeall()))
            GC.gc()
            for quantity in (:appfd, :photons, :assimilation), with_panels in (false, true)
                quantity == :appfd && !with_panels && continue
                Base.invokelatest(render;
                    quantity, with_panels, prepared)
                Core.eval(workspace, :(GLMakie.closeall()))
                GC.gc()
            end
            prepared = nothing
            render = nothing
            GC.gc()
            Base.include(workspace, joinpath(@__DIR__, "5.9_plot_integrated_light.jl"))
        end
        Core.eval(workspace, :(GLMakie.closeall()))
        workspace = nothing
        GC.gc()
        push!(completed, group)
        @info "Saved-output plotting group completed" group
    end
    return completed
end
