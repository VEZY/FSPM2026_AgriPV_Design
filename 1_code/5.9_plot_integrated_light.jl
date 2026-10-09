# Historical filename: colors show growth-cycle net assimilation, in mol CO₂/plant.
using Dates, DataFrames, ArchimedLight, PlantGeom, GLMakie
isdefined(@__MODULE__, :attach_assimilation_to_yearly_scene) || include("attach_assimilation_to_scene.jl")

config_id = 0
scene = attach_assimilation_to_yearly_scene(config_id, Date(2025, 7, 2))
values = integrated_plant_assimilation(; config_id).total_assimilation
lo, hi = extrema(values)
lo == hi && (hi = lo + 1)
color_range = (lo, hi)
fig = Figure()
ax = LScene(fig[1, 1])
plantviz!(ax, scene.mtg; color=:total_assimilation, color_mode=:node,
    colormap=:viridis, colorrange=color_range, color_missing=Makie.to_color(:gray85))
Colorbar(fig[1, 2]; limits=color_range, colormap=:viridis,
    label="Growth-cycle net assimilation (mol CO₂/plant)")
fig
