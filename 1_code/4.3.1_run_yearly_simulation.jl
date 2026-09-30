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

include("methods.jl")
include("simulation.jl")

days = Date(2025, 3, 4):Day(1):Date(2025, 7, 2) |> collect

models = agripv_models()

# meteo = CSV.read("0_simulations/meteo/meteo_data_2025_montpellier.csv", DataFrame)
meteo = read_weather("0_simulations/meteo/meteo_data_2025_montpellier.csv", duration=x -> Hour(1));
metadata = (location="Montpellier", latitude=43.61, longitude=3.878, timezone="Europe/Paris")
meteo = Weather(meteo, metadata);

# Restrict to the growing period:
# start_date, end_date = get_growth_period()  # Format of start_date and end_date: e.g. Date(2025, 6, 25)
start_date = days[0]
end_date = days[end]
meteo_rows = TableOperations.filter(x -> start_date <= Date(Tables.getcolumn(x, :date)) <= end_date, meteo) |> (x -> TimeStepTable(x, metadata));

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

for configID in range(0, 89)
    scene, sim, series, plant_df = make_simulation(pvconfig=get_pvconfig(configID), models=models, meteo=row, options=options)

    write_component_values("2_outputs/simulations/daily/results_config$configID.csv", sim, series)

    CSV.write("2_outputs/simulations/daily/apar_config_$configID.csv", plant_df)
end
