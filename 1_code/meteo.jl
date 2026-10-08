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

"""
    archimed_meteo(meteo, options::LightOptions)

Prepare meteo data for ArchimedLight simulation.

# Arguments

- `meteo`: A `TimeStepTable` or `DataFrame` containing the meteorological data for the simulation.
- `options`: A `LightOptions` object containing the options for the light simulation.

# Returns

- A `TimeStepTable` containing the meteorological data with additional columns for sun azimuth, sun elevation, direct fraction, and incident radiation in PAR and NIR bands.
"""
function archimed_meteo(meteo, options::LightOptions)
    # The 0.15 light model consumes explicit solar geometry and partition.
    # Use ArchimedLight's documented advanced sky stage to retain the
    # same sun reconstruction and clearness assumptions as run_light.
    prepared = prepare_meteo(meteo, options)
    # Keep the site's latitude metadata when reconstructing solar geometry.
    # Montpellier weather supplies 43.61°; DataFrame rows lose this metadata.
    skies = [ArchimedLight.compute_sky(r, options) for r in prepared]
    forcing = DataFrame(prepared)
    forcing.sun_azimuth_deg = getproperty.(skies, :sun_azimuth_deg)
    forcing.sun_elevation_deg = getproperty.(skies, :sun_elevation_deg)
    forcing.direct_fraction = getproperty.(skies, :direct_fraction)
    forcing.Ri_PAR_f = getproperty.(skies, :ri_par_f)
    forcing.Ri_NIR_f = getproperty.(skies, :ri_nir_f)
    return TimeStepTable(forcing, PlantMeteo.metadata(prepared))
end
