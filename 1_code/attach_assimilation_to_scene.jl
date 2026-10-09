using DataFrames, Dates
using MultiScaleTreeGraph
isdefined(@__MODULE__, :load_yearly_scene) || include("saved_simulation.jl")

"""Sum all signed, area-integrated timestep assimilation per planting position (mol CO₂)."""
function integrated_plant_assimilation(; config_id, output_dir=_agripv_yearly_output_dir())
    with_saved_outputs(; config_id, tables=:plants, input_dir=output_dir) do con, metadata
        result = DataFrame(DBInterface.execute(con, """
            SELECT plant_instance_id, sum(assimilation_step) / 1e6 AS total_assimilation
            FROM plants GROUP BY plant_instance_id ORDER BY plant_instance_id
            """))
        all(x -> !ismissing(x), result.plant_instance_id) ||
            throw(ArgumentError("Stable planting IDs are required for cycle aggregation."))
        all(x -> !ismissing(x) && isfinite(x), result.total_assimilation) ||
            throw(ArgumentError("Invalid integrated assimilation values."))
        return result
    end
end

"""Reconstruct saved yearly geometry and attach cycle-total mol CO₂ to each plant and its organs."""
function attach_assimilation_to_yearly_scene(config_id, day; output_dir=_agripv_yearly_output_dir())
    totals = integrated_plant_assimilation(; config_id, output_dir)
    values = Dict(Int(row.plant_instance_id) => row.total_assimilation for row in eachrow(totals))
    scene = load_yearly_scene(; config_id, day, output_dir).scene
    present = Set{Int}()
    MultiScaleTreeGraph.traverse!(scene.mtg) do node
        symbol(node) == :Plant && push!(present, Int(node[:plantID]))
    end
    present == Set(keys(values)) || throw(ArgumentError("Integrated planting IDs differ from saved geometry."))
    function attach!(node, id=nothing)
        symbol(node) == :Plant && (id = Int(node[:plantID]))
        node[:total_assimilation] = isnothing(id) ? nothing : values[id]
        foreach(child -> attach!(child, id), children(node))
    end
    attach!(scene.mtg)
    return scene
end
