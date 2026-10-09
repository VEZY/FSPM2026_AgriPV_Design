using CSV, DataFrames, Dates
using PlantGeom, Colors
using GLMakie
using MultiScaleTreeGraph

# Include necessary modules
cd(@__DIR__)
include("saved_simulation.jl")

"""
Visualize the scene with plants colored by their total assimilation values.
"""
function visualize_assimilation(config_id, day; colormap=:viridis)
    # 1. Load the scene with assimilation values
    scene = attach_assimilation_to_yearly_scene(config_id, day)
    
    # 2. Collect assimilation values for color scaling
    assimilation_values = Float64[]
    traverse!(scene.mtg) do node
        if symbol(node) == :Plant && !ismissing(node[:total_assimilation])
            push!(assimilation_values, node[:total_assimilation])
        end
        return true
    end
    
    min_assim = minimum(assimilation_values)
    max_assim = maximum(assimilation_values)
    
    println("Assimilation range: ", min_assim, " to ", max_assim)
    
    # 3. Create color mapping function
    function get_color(node)
        if symbol(node) == :Plant && !ismissing(node[:total_assimilation])
            # Normalize to 0-1 range
            norm_value = (node[:total_assimilation] - min_assim) / (max_assim - min_assim)
            return get(cgrad(colormap), clamp(norm_value, 0, 1))
        else
            return RGBAf(0.5, 0.5, 0.5, 0.5)  # Gray for non-plant objects
        end
    end
    
    # 4. Apply colors to nodes
    traverse!(scene.mtg) do node
        node[:color] = get_color(node)
        return true
    end
    
    # 5. Create the visualization
    fig = Figure(size=(1200, 800))
    ax = LScene(fig[1, 1])
    
    # Use plantviz! to visualize the MTG directly
    # plantviz! expects the MTG, not the scene geometry
    plantviz!(ax, scene.mtg; color=:color)
    
    # Add colorbar
    Colorbar(fig[1, 2], 
        limits=(min_assim, max_assim), 
        colormap=colormap, 
        label="Total Assimilation\n(mol CO₂)",
        vertical=true
    )
    
    # Set camera angle for better view
    # ax.scene.camera.eyeposition[] = Vec3f(5, 5, 10)
    # ax.scene.camera.lookat[] = Vec3f(0, 0, 0)
    
    # Add title
    # ax.title = "AgriPV Scene - $(day): Total Assimilation per Plant"
    
    return fig
end

# Example usage:
fig = visualize_assimilation(0, Date("2025-07-02"))
# save("assimilation_2025-07-02.png", fig)