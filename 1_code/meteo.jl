using Dates
using PlantMeteo

function get_meteo(day::Date)
    # meteo = read_weather("0_simulations/meteo/meteo_data_2025_montpellier.csv", duration=x -> Hour(1))
    meteo = CSV.read("0_simulations/meteo/meteo_data_2025_montpellier.csv", DataFrame; dateformat="yyyy-mm-ddTHH:MM:SS")
    meteo.duration .= Hour(1)
    metadata = (location="Montpellier", latitude=43.61, longitude=3.878, timezone="Europe/Paris")
    meteo = Weather(meteo, metadata)

    # Restrict to the growing period:
    meteo_rows = TableOperations.filter(x -> Date(Tables.getcolumn(x, :date)) == day, meteo) |> (x -> TimeStepTable(x, metadata))

    return meteo_rows
end

function get_meteo(days::Vector{Date})
    meteo = CSV.read("0_simulations/meteo/meteo_data_2025_montpellier.csv", DataFrame; dateformat="yyyy-mm-ddTHH:MM:SS")
    meteo.duration .= Hour(1)
    metadata = (location="Montpellier", latitude=43.61, longitude=3.878, timezone="Europe/Paris")
    meteo = Weather(meteo, metadata)

    # Restrict to the growing period:
    meteo_rows = TableOperations.filter(x -> Date(Tables.getcolumn(x, :date)) in days, meteo) |> (x -> TimeStepTable(x, metadata))

    return meteo_rows
end