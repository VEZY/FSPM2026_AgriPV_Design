using CSV, DataFrames
using Dates
using ArchimedLight
using PlantGeom, GLMakie

# Include necessary modules
isdefined(@__MODULE__, :attach_assimilation_to_yearly_scene) || include("attach_assimilation_to_scene.jl")


# df_integrated = CSV.read("2_outputs/simulations/yearly/last_day_ids.csv", DataFrame)
# sort!(df_integrated, [:plant_id])

# df_temp = filter(:datetime => x -> DateTime(x) == DateTime("2025-07-02T00:00:00"), df_integrated)

# filter(:plant_instance_id => ==(5), df_temp)

# df_nb_of_nodes_per_plant = combine(groupby(df_temp, :plant_instance_id), nrow => :nb_of_nodes)
# length(unique(df_temp.plant_instance_id))
# == nrow(df_nb_of_nodes_per_plant) || throw(ArgumentError("Mismatch in number of unique plant IDs and rows in the grouped DataFrame."))

# bar =
#     data(df_nb_of_nodes_per_plant) *
#     mapping(
#         :plant_id => "Plant ID",
#         :nb_of_nodes => "Number of Nodes"
#     ) *
#     visual(Bars, color=:plant_id, colormap=:viridis)

# draw(bar; figure=(size=(900, 700), title="Number of nodes per plant ID"))



# Load scene
scene = attach_assimilation_to_yearly_scene(0, Date("2025-07-02"))

# Visualize with color based on total_assimilation
begin
    fig = Figure()
    ax = LScene(fig[1, 1])

    # This will automatically use the :total_assimilation attribute for coloring
    plantviz!(ax, scene; color=:total_assimilation, colormap=:viridis)

    # Add colorbar
    Colorbar(fig[1, 2], label="Total Assimilation (mol CO₂)")

    fig
end
