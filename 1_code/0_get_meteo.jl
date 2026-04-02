using PlantMeteo, Dates, CSV

location_montpellier = (lat=43.610, lon=3.878)
# w = get_weather(location_montpellier.lat, location_montpellier.lon, [Date(2025, 1, 1), Date(2025, 12, 31)])
params = PlantMeteo.OpenMeteo()
period = [Date(2025, 1, 1), Date(2025, 12, 31)]
atms_archive, metadata = PlantMeteo.fetch_openmeteo(params.historical_server, location_montpellier.lat, location_montpellier.lon, period[1], period[end], params)
tst = TimeStepTable(atms_archive, metadata);
CSV.write("0_simulations/meteo/meteo_data_2025_montpellier.csv", tst)