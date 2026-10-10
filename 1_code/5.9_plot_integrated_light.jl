# Historical filename: colors show growth-cycle net assimilation, in mol CO₂/plant.
using Dates, DataFrames, ArchimedLight, PlantGeom, GLMakie
isdefined(@__MODULE__, :attach_assimilation_to_yearly_scene) || include("attach_assimilation_to_scene.jl")

"""Plot and save growth-cycle net assimilation on a verified saved daily scene."""
function plot_integrated_assimilation(; config_id=0, day=nothing,
    input_dir=_agripv_yearly_output_dir(),
    output_dir=joinpath(_agripv_project_root(), "2_outputs", "cumulative_assimilation"))
    metadata = TOML.parsefile(joinpath(input_dir, "scene_config_$(config_id).toml"))
    isnothing(day) && (day = maximum(Date.(metadata["days"])))
    scene = attach_assimilation_to_yearly_scene(config_id, day; output_dir=input_dir)
    values = integrated_plant_assimilation(; config_id, output_dir=input_dir).total_assimilation
    lo, hi = extrema(values)
    lo == hi && (hi = lo + 1)
    color_range = (lo, hi)
    fig = Figure(size=(1200, 850))
    Label(fig[0, 1:2], "Growth-cycle net assimilation · Config $(config_id)", fontsize=24)
    ax = LScene(fig[1, 1])
    plantviz!(ax, scene.mtg; color=:total_assimilation, color_mode=:node,
        colormap=:viridis, colorrange=color_range, color_missing=Makie.to_color(:gray85))
    Colorbar(fig[1, 2]; limits=color_range, colormap=:viridis,
        label="Growth-cycle net assimilation (mol CO₂/plant)")
    Label(fig[2, 1:2], "$(first(metadata["days"])) → $(last(metadata["days"])) · geometry: $(day)", fontsize=18)
    mkpath(output_dir)
    path = joinpath(output_dir, "integrated_assimilation_3d_config_$(config_id).png")
    save(path, fig; px_per_unit=1.5)
    return (; figure=fig, scene, path, color_range)
end

integrated_assimilation = plot_integrated_assimilation()
