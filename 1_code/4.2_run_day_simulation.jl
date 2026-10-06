using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using PlantGeom # For the growth and visualization API
using ArchimedLight
using PlantMeteo, Dates, TableOperations, PlantMeteo.Tables
using AlgebraOfGraphics, DataFrames, Statistics, CSV
using PlantBiophysics, PlantSimEngine

include("simulation.jl")
include("pvconfig.jl")

day = Date(2025, 7, 2)
configIDs = range(0, 0)

for configID in configIDs
    # options.scene_rotation_deg = get_pvconfig(configID).panel_orientation
    # row = prepare_meteo(meteo_rows, options);

    println("Config $(configID)...")
    sim, series, plant_df = day_simulation(pvconfig=get_pvconfig(configID), day=day)
    println("\tDONE")

    write_component_values("2_outputs/simulations/daily/results_config$(configID)_$(day).csv", sim, series)

    CSV.write("2_outputs/simulations/daily/apar_config_$(configID)_$(day).csv", plant_df)
end
