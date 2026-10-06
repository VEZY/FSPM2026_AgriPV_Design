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

configIDs = [Int8(x) for x in range(0,3)]

# TODO
# read_component_values()

for configID in configIDs
    plant_df = CSV.read("2_outputs/simulations/daily/apar_config_$configID.csv", DataFrame)
    apar_sum_plant = combine(groupby(plant_df, :plant_id), :apar => sum => :apar_sum)
    minimum(apar_sum_plant.apar_sum), maximum(apar_sum_plant.apar_sum), mean(apar_sum_plant.apar_sum)
    minimum(apar_sum_plant.apar_sum) / maximum(apar_sum_plant.apar_sum)
    plant_df_avg = combine(groupby(plant_df, :date), :apar => mean => :apar_mean)
end

# Make the plot of aPAR average with all configurations

begin
    f = Figure(size=(900, 700))
    ax = Axis(f[1, 1], title="Average assimilation over the day", xlabel="Time of day", ylabel="A (μmol plant⁻¹ hour⁻¹)", xticks=0:2:24)

    for configID in configIDs
        plt = data(plant_df) *
            mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation, group=:plant_id) *
            visual(Lines, alpha=0.05)
        plant_df_avg = combine(groupby(plant_df, :date), :assimilation => mean => :assimilation_mean)
        plt_avg = data(plant_df_avg) *
            mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation_mean) *
            visual(Lines, color=:red, linewidth=3)

        draw!(ax, plt_avg)
    end

    # hidedecorations!(ax_inset)
    f
end
save("2_outputs/daily_apar_crop_3d.png", f, update=false, px_per_unit=3.0)


CSV.write("2_outputs/daily_apar_crop_horizontal_design.csv", plant_df_0)
CSV.write("2_outputs/daily_apar_crop_tilted_design.csv", plant_df)

plant_df_0 = CSV.read("2_outputs/daily_apar_crop_horizontal_design.csv", DataFrame)
plant_df = CSV.read("2_outputs/daily_apar_crop_tilted_design.csv", DataFrame)

apar_sum_plant_0 = combine(groupby(plant_df_0, :plant_id), :apar => sum => :apar_sum)
apar_sum_plant_ref = combine(groupby(plant_df, :plant_id), :apar => sum => :apar_sum)
minimum(apar_sum_plant_0.apar_sum), maximum(apar_sum_plant_0.apar_sum), mean(apar_sum_plant_0.apar_sum)
minimum(apar_sum_plant_ref.apar_sum), maximum(apar_sum_plant_ref.apar_sum), mean(apar_sum_plant_ref.apar_sum)

minimum(apar_sum_plant_0.apar_sum) / maximum(apar_sum_plant_0.apar_sum)


plant_df_0_avg = combine(groupby(plant_df_0, :date), :apar => mean => :apar_mean)
plant_df_avg = combine(groupby(plant_df, :date), :apar => mean => :apar_mean)

horizontal_design_compared_to_ref = (sum(plant_df_0_avg.apar_mean) / sum(plant_df_avg.apar_mean) * 100) - 100
