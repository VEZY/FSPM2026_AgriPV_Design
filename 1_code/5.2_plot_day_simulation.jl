using GLMakie, PlantGeom

if !isdefined(@__MODULE__, :attach_outputs!)
    include("simulation_outputs.jl")
end
isdefined(@__MODULE__, :load_day_outputs) || include("saved_simulation.jl")

function _output_plot_range(table, variable, timestep)
    values = Float64[value for (step, value) in zip(table.timestep, table[!, variable])
                               if step == timestep && value isa Real && isfinite(value)]
    isempty(values) && throw(ArgumentError("No finite $variable values at timestep $timestep."))
    lower, upper = extrema(values)
    if lower == upper
        # PlantViz normalizes by upper-lower; zero nighttime radiation must
        # also have a nonzero display range.
        iszero(lower) && return (0.0, 1.0)
        padding = abs(lower) * 0.05
        return (lower - padding, upper + padding)
    end
    return (lower, upper)
end

"""Reload a saved CSV, rebuild its scene and plot one variable at one timestep."""
function plot_saved_output(; config_id, day, variable=:A, timestep=13,
    table=:leaves, output_dir=_agripv_daily_output_dir(), kwargs...)
    saved = load_day_outputs(; config_id, day, output_dir, tables=(table,))
    return plot_output(saved.scene.mtg, getproperty(saved, table); variable, timestep, kwargs...)
end

"""
    plot_output(mtg, table; variable=:A, timestep=13, label=string(variable), ...)

Attach one output snapshot by MTG node ID and color its geometry with PlantViz.
Use `result.leaves` for A/temperature/transpiration and `result.light` for
radiation on leaves, stems, panels and ground. For a plant subtree, filter the
table by `plant_id` first. Plant summaries attach to Plant nodes, which have
no mesh themselves. Execute through Kaimon with `mt=true` for GLMakie.
"""
function plot_output(mtg, table;
    variable=:A, timestep=13, label=string(variable), colorrange=nothing,
    colormap=:thermal, color_missing=:gray85, kwargs...)
    range = isnothing(colorrange) ? _output_plot_range(table, variable, timestep) : colorrange
    all(isfinite, range) && first(range) < last(range) ||
        throw(ArgumentError("colorrange must be finite and strictly increasing."))
    # PlantViz appends missing colors into a Colorant vector directly.
    missing_color = Makie.to_color(color_missing)
    attach_outputs!(mtg, table; timestep, variables=(variable,))
    figure, axis, plot = plantviz(mtg;
        color=variable, color_mode=:node, colorrange=range, colormap,
        color_missing=missing_color, kwargs...)
    PlantGeom.colorbar(figure[1, 2], plot; label)
    return figure, axis, plot
end

# Or after result = day_simulation(...):
# f, ax, p = plot_output(result.scene.mtg, result.leaves;
#     variable=:A, timestep=13, label="Net assimilation (μmol CO₂ m⁻² s⁻¹)")
# f, ax, p = plot_output(result.scene.mtg, result.light;
#     variable=:Ra_PAR_f, timestep=13, label="Absorbed PAR (W m⁻²)")

config_id = 1
day = Date(2025, 7, 2)
variable = :Ra_PAR_f
timestep = 12
f, ax, p = plot_saved_output(; config_id, day, variable, timestep, table=:light, output_dir=_agripv_daily_output_dir())

f