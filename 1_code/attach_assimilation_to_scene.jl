using CSV, DataFrames, Dates
using MultiScaleTreeGraph

# Include necessary modules
isdefined(@__MODULE__, :load_yearly_scene) || include("saved_simulation.jl")

"""
    attach_assimilation_to_yearly_scene(config_id, day; output_dir=...)

Load the scene for a specific day from yearly simulation outputs and attach
total carbon assimilation values from the integrated output to each plant.

Returns the scene with assimilation values attached to Plant nodes.
"""
function attach_assimilation_to_yearly_scene(config_id, day; 
    output_dir=joinpath(_agripv_project_root(), "2_outputs", "simulations", "yearly"))
    
    # 1. Load the integrated assimilation data
    integrated_file = joinpath(output_dir, "integrated_outs_config_$(config_id).csv")
    isfile(integrated_file) || throw(ArgumentError("Integrated output file not found: $integrated_file"))
    
    df_integrated = CSV.read(integrated_file, DataFrame)
    sort!(df_integrated, [:plant_instance_id])
    
    # 2. Create a mapping from plant_instance_id to total assimilation
    assimilation_map = Dict{Int, Float64}()
    for row in eachrow(df_integrated)
        assimilation_map[row.plant_instance_id] = row.total_assimilation
    end
    
    # 3. Load the scene for the specified day from yearly configuration
    result = load_yearly_scene(; config_id, day, output_dir)
    scene = result.scene
    
    # 4. Attach the total assimilation to each Plant node in the scene
    plant_count = 0
    MultiScaleTreeGraph.traverse!(scene.mtg) do node
        if MultiScaleTreeGraph.symbol(node) == :Plant
            plant_id = node[:plantID]
            if haskey(assimilation_map, plant_id)
                node[:total_assimilation] = assimilation_map[plant_id]
                plant_count += 1
            else
                # Optionally handle missing plants
                node[:total_assimilation] = missing
            end
        end
        return true
    end
    
    @info "Attached total assimilation values to $plant_count plants in the scene for $day"
    
    return scene
end

"""
Example usage:

# Load the scene for 2025-07-02 with assimilation values attached
scene = attach_assimilation_to_yearly_scene(0, Date("2025-07-02"))

# Now you can use the scene for visualization or further analysis
# Each Plant node has a :total_assimilation attribute with the cumulative value
"""

# Uncomment to run the example:
# scene = attach_assimilation_to_yearly_scene(0, Date("2025-07-02"))