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

include("simulation.jl")

configIDs = range(0,0)
day = Date(2025, 7, 2)

# TODO
values_dfs = []
for configID in configIDs
    push!(values_dfs, read_aPAR_from_component_values(csv_path="2_outputs/simulations/daily/results_config$(configID)_$(day).csv"))
end

# Make the plot of aPAR average with all configurations

begin
    f = Figure(size=(900, 700))
    # ax1 = Axis(f[1, 1], title="Average assimilation over the day", xlabel="Time of day", ylabel="A (μmol plant⁻¹ hour⁻¹)", xticks=0:2:24)

    configID = 0 + 1
    ax1 = Axis(f[1, 1], title="Config $configID", xlabel="Time of day", ylabel="A (μmol plant⁻¹ hour⁻¹)", xticks=0:2:24)
    for plant_id in range(minimum(values_dfs[configID].object_id), maximum(values_dfs[configID].object_id))
        ndf = filter(:object_id => ==(plant_id), values_dfs[configID])
        plt_apar = data(ndf) *
            mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation_mean) *
            visual(Lines, color=:red, linewidth=3)
        draw!(ax1, plt_apar)
    end

    # for configID in configIDs
    #     # plt = data(plant_df[configID]) *
    #     #     mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation, group=:plant_id) *
    #     #     visual(Lines, alpha=0.05)
    #     plant_df_avg[configID] = combine(groupby(plant_df[configID], :date), :assimilation => mean => :assimilation_mean)
    #     plt_avg = data(plant_df_avg[configID]) *
    #         mapping(:date => (x -> Hour(x).value) => "Hour", :assimilation_mean) *
    #         visual(Lines, color=:red, linewidth=3)

    #     draw!(ax, plt_avg, label="Config $configID")
    # end

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
