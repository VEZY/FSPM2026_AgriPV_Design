# Convert the hourly PlantMeteo/Open-Meteo CSV to a daily STICS climate file.
using CSV, DataFrames, Dates, Statistics, Printf

project_dir = dirname(@__DIR__)
input_file = joinpath(project_dir, "0_simulations", "meteo", "meteo_data_2025_montpellier.csv")
output_dir = joinpath(project_dir, "0_simulations", "stics", "wheat")
station_name = "montpellier"
wind_height_m = 10.0  # Open-Meteo supplies wind at 10 m; STICS expects 2 m.
missing_pet = -999.9  # STICS calculates PET when the station's codeetp = 2.

hourly = CSV.read(input_file, DataFrame; types=Dict(:date => DateTime), strict=true)
required_columns = [:date, :duration, :T, :Ri_SW_f, :Precipitations, :Wind, :e, :Cₐ]
missing_columns = setdiff(required_columns, propertynames(hourly))
isempty(missing_columns) || error("Missing input columns: $(join(missing_columns, ", ")).")
nrow(hourly) > 0 || error("The input climate file is empty.")

for column in required_columns
    any(ismissing, hourly[!, column]) && error("Missing values in column $column.")
end
for column in [:T, :Ri_SW_f, :Precipitations, :Wind, :e, :Cₐ]
    all(isfinite, hourly[!, column]) || error("Non-finite values in column $column.")
    any(==(-999.9), hourly[!, column]) && error("Missing-value code -999.9 in column $column.")
end
for column in [:Ri_SW_f, :Precipitations, :Wind, :e, :Cₐ]
    all(>=(0), hourly[!, column]) || error("Negative values in column $column.")
end

all(==("1 hour"), hourly.duration) || error("Expected duration = '1 hour' for every row.")
sort!(hourly, :date)
all(==(Hour(1)), diff(hourly.date)) || error("Duplicate timestamps or gaps in the hourly data.")

# Keep the dates exactly as exported (UTC with the defaults in 0_get_meteo.jl).
# Open-Meteo rain and radiation describe the PRECEDING hour, so their daily
# totals cover 23:00 the previous day to 23:00 the current day.
# See https://open-meteo.com/en/docs/historical-weather-api
hourly.day = Date.(hourly.date)
days = groupby(hourly, :day; sort=true)

for weather in days
    expected_hours = DateTime(first(weather.day)) .+ Hour.(0:23)
    weather.date == expected_hours || error("Incomplete day: $(first(weather.day)); expected 00:00–23:00.")
end

# Converting hourly measurements to the units required by STICS.
# Global shortwave radiation: W m^-2 * seconds / 1e6 = MJ m^-2 per hour.
# Use total shortwave radiation, NOT PAR or only its direct/diffuse component.
hourly.radiation_MJ_m2 = hourly.Ri_SW_f .* 3600.0 ./ 1e6

# Actual vapour pressure: kPa -> hPa (mbar).
hourly.vapour_pressure_hPa = hourly.e .* 10.0

# FAO-56, equation 47: convert wind at height z to wind at 2 m over short grass.
# https://www.fao.org/4/x0490e/x0490e07.htm
# Set wind_height_m = 2.0 for an input file that already contains 2 m wind.
wind_height_m >= 2.0 || error("Expected a wind measurement height of at least 2 m.")
wind_factor = wind_height_m == 2.0 ? 1.0 : 4.87 / log(67.8 * wind_height_m - 5.42)
hourly.wind_2m = hourly.Wind .* wind_factor

# Aggregate the hourly records into one row per day.
daily = combine(
    groupby(hourly, :day; sort=true),
    :T => minimum => :tmin,
    :T => maximum => :tmax,
    :radiation_MJ_m2 => sum => :radiation,
    :Precipitations => sum => :rain,
    :wind_2m => mean => :wind,
    :vapour_pressure_hPa => mean => :vapour_pressure,
    :Cₐ => mean => :co2,
)
daily.year = year.(daily.day)

# Write the standard STICS format: spaces between columns, no header.
# Columns: station year month day DOY Tmin Tmax radiation PET rain wind vapour CO2
# Units:                            degC degC MJ/m2/day mm/day mm/day m/s hPa ppm
# PET is intentionally missing: the station must calculate it (codeetp=2).

mkpath(output_dir)
for weather_year in groupby(daily, :year; sort=true)
    output_file = joinpath(output_dir, "$(station_name).$(first(weather_year.year))")
    open(output_file, "w") do io
        for row in eachrow(weather_year)
            @printf(io, "%s %4d %2d %2d %3d %.3f %.3f %.6f %.1f %.3f %.6f %.6f %.3f\n",
                station_name, year(row.day), month(row.day), day(row.day), dayofyear(row.day),
                row.tmin, row.tmax, row.radiation, missing_pet, row.rain,
                row.wind, row.vapour_pressure, row.co2)
        end
    end
    @info "Wrote daily STICS climate" file=output_file days=nrow(weather_year) first_day=first(weather_year.day) last_day=last(weather_year.day)
end
