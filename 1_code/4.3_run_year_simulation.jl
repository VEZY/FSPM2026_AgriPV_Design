using Colors # For color definitions
using Agrivoltaics # For the solar panel structure and mesh generation
using GeometryBasics # For geometry
using MultiScaleTreeGraph # For the MTG data structure
using PlantGeom # For the growth and visualization API
using ArchimedLight
using PlantMeteo, Dates, TableOperations, PlantMeteo.Tables
using AlgebraOfGraphics, DataFrames, Statistics, CSV
using PlantBiophysics, PlantSimEngine

include("scene.jl")
include("simulation.jl")
include("meteo.jl")

days = Date(2025, 3, 4):Day(1):Date(2025, 7, 2) |> collect
configIDs = range(0, 0)

models = agripv_models()
meteo_rows = get_meteo(days)

options = LightOptions(
    # turtle_sectors=46,
    turtle_sectors=16,
    pixel_size=0.01,
    toricity=true,
    scattering=true,
    cache_radiation=true,
    all_in_turtle=true,
    include_sky_fraction=true,
)

row = prepare_meteo(meteo_rows, options);

for configID in configIDs
    scene, sim, series, plant_df = day_simulation(pvconfig=get_pvconfig(configID), models=models, meteo=row, options=options)

    write_component_values("2_outputs/simulations/yearly/results_config$configID.csv", sim, series)

    CSV.write("2_outputs/simulations/daily/apar_config_$configID.csv", plant_df)
end
