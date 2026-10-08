module AgripvMeteoTests

using Test, Dates, CSV, DataFrames, PlantMeteo, ArchimedLight, TableOperations
using PlantMeteo.Tables
include(joinpath(@__DIR__, "..", "meteo.jl"))

export METEO_TEST_RESULT

const SKY_COLUMNS = ((:sun_azimuth_deg, :sun_azimuth_deg),
    (:sun_elevation_deg, :sun_elevation_deg), (:direct_fraction, :direct_fraction),
    (:Ri_PAR_f, :ri_par_f), (:Ri_NIR_f, :ri_nir_f))

# Explicit site coordinates form a reference independent of metadata propagation.
function sky_reference(meteo, options, latitude)
    reference = DataFrame(prepare_meteo(meteo, options))
    reference.latitude = fill(latitude, nrow(reference))
    return [ArchimedLight.compute_sky(row, options) for row in eachrow(reference)]
end

const METEO_TEST_RESULT = @testset "Solar geometry respects weather-site latitude" begin
    days = [Date(2025, 3, 30), Date(2025, 7, 2)] # DST transition and summer.
    options = LightOptions(; turtle_sectors=46, all_in_turtle=true, scene_rotation_deg=180.0)
    period = get_meteo(days)
    @test PlantMeteo.metadata(period)["latitude"] == 43.61
    @test PlantMeteo.metadata(period)["longitude"] == 3.878
    @test PlantMeteo.metadata(period)["timezone"] == "Europe/Paris"
    period_prepared = DataFrame(archimed_meteo(period, options))

    for day in days
        raw = get_meteo(day)
        prepared = archimed_meteo(raw, options)
        frame, raw_frame = DataFrame(prepared), DataFrame(raw)
        @test PlantMeteo.metadata(raw)["latitude"] == 43.61
        @test PlantMeteo.metadata(prepared)["latitude"] == 43.61
        @test PlantMeteo.metadata(prepared)["longitude"] == 3.878
        @test PlantMeteo.metadata(prepared)["timezone"] == "Europe/Paris"
        @test DateTime.(frame.date) == DateTime.(raw_frame.date)
        @test frame.T == raw_frame.T
        @test frame.duration == raw_frame.duration
        @test all(column -> column in propertynames(frame), first.(SKY_COLUMNS))
        period_day = filter(row -> Date(row.date) == day, period_prepared)
        @test isequal(select(frame, Not(:date)), select(period_day, Not(:date)))
        reference = sky_reference(raw, options, 43.61)
        for (column, source) in SKY_COLUMNS
            @test isapprox(frame[!, column], getproperty.(reference, source); rtol=1e-10, nans=true)
        end
        old_latitude = sky_reference(raw, options, 48.0)
        @test !isapprox(frame.sun_elevation_deg, getproperty.(old_latitude, :sun_elevation_deg))
    end

    # A second location catches a hardcoded Montpellier latitude as well.
    other_metadata = merge(PlantMeteo.metadata(period), Dict("location" => "Latitude test", "latitude" => 10.0))
    other = TimeStepTable(DataFrame(period), other_metadata)
    other_prepared = archimed_meteo(other, options)
    @test PlantMeteo.metadata(other_prepared)["latitude"] == 10.0
    other_frame = DataFrame(other_prepared)
    reference = sky_reference(other, options, 10.0)
    for (column, source) in SKY_COLUMNS
        @test isapprox(other_frame[!, column], getproperty.(reference, source); rtol=1e-10, nans=true)
    end
    @test !isapprox(other_frame.sun_elevation_deg, period_prepared.sun_elevation_deg)
end

end # module AgripvMeteoTests
