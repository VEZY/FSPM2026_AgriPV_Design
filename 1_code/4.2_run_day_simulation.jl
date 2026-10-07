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
include("saved_simulation.jl")

day = Date(2025, 7, 2)
configIDs = 0:3

for configID in configIDs
    # configID = 0
    # options.scene_rotation_deg = get_pvconfig(configID).panel_orientation
    # row = prepare_meteo(meteo_rows, options);

    println("Config $(configID)...")
    result = day_simulation(pvconfig=get_pvconfig(configID), day=day)
    println("\tDONE")

    # write_component_values("2_outputs/simulations/daily/results_config$(configID)_$(day).csv", sim, series)

    write_day_outputs(result; config_id=configID)
end
