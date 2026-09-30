using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using PlantGeom # For the growth and visualization API
using GLMakie
using ArchimedLight
using PlantMeteo, Dates, TableOperations, PlantMeteo.Tables
using AlgebraOfGraphics, DataFrames, Statistics, CSV
using PlantBiophysics, PlantSimEngine

# TODO
# read_component_values()

for configID in range(0,89)
    plant_df = CSV.read("2_outputs/simulations/daily/apar_config_$configID.csv", DataFrame)
    apar_sum_plant = combine(groupby(plant_df, :plant_id), :apar => sum => :apar_sum)
    minimum(apar_sum_plant.apar_sum), maximum(apar_sum_plant.apar_sum), mean(apar_sum_plant.apar_sum)
    minimum(apar_sum_plant.apar_sum) / maximum(apar_sum_plant.apar_sum)
    plant_df_avg = combine(groupby(plant_df, :date), :apar => mean => :apar_mean)
end

horizontal_design_compared_to_ref = (sum(plant_df_0_avg.apar_mean) / sum(plant_df_ref_avg.apar_mean) * 100) - 100

# Make the plot with the incident PAR on the tiled geometry of the noon timestep,
# and an inset with the plant geometry colored in green,
# and the daily absorbed PAR by the crop:
wheat_plant = read_opf("0_simulations/archicrop/wheat/static/plant_1995-06-24.opf", mtg_type=NodeMTG)
tiled_ref = ArchimedLight.tile_light_geometry(scene_ref, series_ref; nx=40, ny=3)
tiled_0 = ArchimedLight.tile_light_geometry(scene_0, series_0; nx=40, ny=3)
# tiled_ref = ArchimedLight.tile_light_geometry(scene_ref, series_ref; nx=1, ny=1)
# tiled_0 = ArchimedLight.tile_light_geometry(scene_0, series_0; nx=1, ny=1)

begin
    f = Figure(size=(900, 700))
    ax1 = Axis3(
        f[1:2, 1:2],
        aspect=:data,
        title="A. Incident PAR at 12:00 on design 1",
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
        # azimuth=0.0,
    )
    p = ArchimedLight.lightplot!(ax1, tiled_ref, series_ref; color=:Ri_PAR_f, colormap=:thermal, timestep=12)

    ax2 = Axis3(
        f[1:2, 3:4],
        aspect=:data,
        title="B. Incident PAR at 12:00 on design 2",
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
        # azimuth=0.0
    )
    zlims!(ax2, zmin(scene_ref.mtg), zmax(scene_ref.mtg)) # Set the same z limits for both plots to make them comparable
    p = ArchimedLight.lightplot!(ax2, tiled_0, series_0; color=:Ri_PAR_f, colormap=:thermal, timestep=12)

    # Plant alone:
    ax_3 = Axis3(
        f[3, 1:2],
        aspect=:data,
        title="C. Individual wheat plant",
        xticks=[-0.2, 0.2],
        yticks=[-0.2, 0.2],
        xlabel="x (m)",
        ylabel="y (m)",
        zlabel="z (m)",
    )

    plantviz!(
        ax_3,
        wheat_plant;
        color=:green,
    )

    Colorbar(f[1:2, 5], p, label="Incident PAR (W m⁻²)")

    ax4 = Axis(f[3, 3:5], title="D. Assimilation per plant over the day", xlabel="Time of day", ylabel="A (μmol plant⁻¹ hour⁻¹)", xticks=0:2:24)
    plt = data(plant_df_ref) *
        mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation, group=:plant_id) *
        visual(Lines, alpha=0.05)
    plant_df_ref_avg = combine(groupby(plant_df_ref, :date), :assimilation => mean => :assimilation_mean)
    plt_avg = data(plant_df_ref_avg) *
        mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation_mean) *
        visual(Lines, color=:red, linewidth=3)
    plt_0 = data(plant_df_0) *
        mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation, group=:plant_id) *
        visual(Lines, alpha=0.05, color=:black, linestyle=:dash)
    plant_df_0_avg = combine(groupby(plant_df_0, :date), :assimilation => mean => :assimilation_mean)
    plt_avg_0 = data(plant_df_0_avg) *
        mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation_mean) *
        visual(Lines, color=:red, linewidth=3, linestyle=:dash)

    draw!(ax4, plt + plt_0 + plt_avg + plt_avg_0)
    # draw!(ax4, plt)

    # hidedecorations!(ax_inset)
    f
end
save("2_outputs/daily_apar_crop_3d.png", f, update=false, px_per_unit=3.0)


CSV.write("2_outputs/daily_apar_crop_horizontal_design.csv", plant_df_0)
CSV.write("2_outputs/daily_apar_crop_tilted_design.csv", plant_df_ref)

plant_df_0 = CSV.read("2_outputs/daily_apar_crop_horizontal_design.csv", DataFrame)
plant_df_ref = CSV.read("2_outputs/daily_apar_crop_tilted_design.csv", DataFrame)

apar_sum_plant_0 = combine(groupby(plant_df_0, :plant_id), :apar => sum => :apar_sum)
apar_sum_plant_ref = combine(groupby(plant_df_ref, :plant_id), :apar => sum => :apar_sum)
minimum(apar_sum_plant_0.apar_sum), maximum(apar_sum_plant_0.apar_sum), mean(apar_sum_plant_0.apar_sum)
minimum(apar_sum_plant_ref.apar_sum), maximum(apar_sum_plant_ref.apar_sum), mean(apar_sum_plant_ref.apar_sum)

minimum(apar_sum_plant_0.apar_sum) / maximum(apar_sum_plant_0.apar_sum)


plant_df_0_avg = combine(groupby(plant_df_0, :date), :apar => mean => :apar_mean)
plant_df_ref_avg = combine(groupby(plant_df_ref, :date), :apar => mean => :apar_mean)

horizontal_design_compared_to_ref = (sum(plant_df_0_avg.apar_mean) / sum(plant_df_ref_avg.apar_mean) * 100) - 100
