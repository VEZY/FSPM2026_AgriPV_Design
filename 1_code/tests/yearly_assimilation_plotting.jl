module AgripvYearlyAssimilationPlottingTests

using Test, Dates, DataFrames, TOML
include(joinpath(@__DIR__, "..", "yearly_assimilation_plotting.jl"))

const CONFIG_ID = 73
const DAYS = [Date(2025, 3, 4), Date(2025, 3, 5)]
const STAMPS = [DateTime(day) + Hour(hour) for day in DAYS for hour in (12, 13)]

function yearly_assimilation_fixture()
    # Arbitrary positive IDs exercise persistent identity independently of node
    # numbering. Negative hourly net assimilation must remain in the integral.
    table = DataFrame(plant_instance_id=repeat([7, 19]; inner=4),
        datetime=repeat(STAMPS, 2),
        assimilation_step=[1.0, -0.5, 2.0, -1.0, 4.0, -1.0, 0.0, -2.0])
    allowmissing!(table)
    return table
end

function save_yearly_assimilation_fixture(root, table; forcing=DataFrame(date=STAMPS))
    function write_table(table, name)
        files = _agripv_write_parquet(table, joinpath(root, name); day=first(DAYS), batch_rows=3)
        for file in files
            file["file"] = joinpath(name, file["file"])
        end
        return _agripv_parquet_info(files)
    end
    metadata = Dict("config_id" => CONFIG_ID, "simulation" => "growth_period",
        "plant_instance_identity_scope" => "configuration", "days" => string.(DAYS),
        "scenes" => [Dict("scene" => Dict("day" => string(day),
            "plant_rotations_rad" => [0.0, 0.0])) for day in DAYS],
        "tables" => Dict("plants" => write_table(table, "plants")),
        "forcing" => write_table(forcing, "forcing"))
    open(joinpath(root, "scene_config_$(CONFIG_ID).toml"), "w") do io
        TOML.print(io, metadata)
    end
    return metadata
end

const YEARLY_ASSIMILATION_PLOTTING_TEST_RESULT = @testset "All-plant yearly assimilation integrates signed steps" begin
    mktempdir() do root
        table = yearly_assimilation_fixture()
        save_yearly_assimilation_fixture(root, table)
        summarize(; kwargs...) = summarize_year_assimilation(; config_id=CONFIG_ID, input_dir=root, kwargs...)
        daily, hourly = summarize(), summarize(; curve_sampling=:hourly)
        @test daily.curve_sampling == :daily
        @test nrow(daily.individual) == 4
        @test nrow(hourly.individual) == 8
        @test sort(unique(daily.individual.plant_instance_id)) == [7, 19]
        @test all(==(CONFIG_ID), daily.individual.configID)
        @test daily.individual.datetime == repeat(STAMPS[[2, 4]], 2)
        @test daily.individual.assimilation_cumulative == [0.5, 1.5, 3.0, 1.0]
        @test hourly.individual.assimilation_cumulative == [1.0, 0.5, 2.5, 1.5, 4.0, 3.0, 3.0, 1.0]
        @test isequal(daily.whole_crop, hourly.whole_crop)
        @test daily.whole_crop.assimilation_cumulative_sum == [5.0, 3.5, 5.5, 2.5]
        @test sum(filter(:datetime => ==(last(STAMPS)), daily.individual).assimilation_cumulative) ==
            last(daily.whole_crop.assimilation_cumulative_sum)
        @test all(==(2), daily.coverage.source_rows)

        # The result is independent of persisted row/shard order.
        save_yearly_assimilation_fixture(root, reverse(table))
        @test isequal(summarize().individual, daily.individual)
        for change! in (t -> t.plant_instance_id[1] = missing,
            t -> t.plant_instance_id[1] = -7, t -> t.datetime[1] = missing,
            t -> t.assimilation_step[1] = missing, t -> t.assimilation_step[1] = NaN,
            t -> t.assimilation_step[1] = Inf, t -> push!(t, t[1, :]),
            t -> deleteat!(t, 1), t -> t.plant_instance_id[end] = 29,
            t -> t.datetime[1] += Day(10))
            malformed = copy(table)
            change!(malformed)
            save_yearly_assimilation_fixture(root, malformed)
            @test_throws ArgumentError summarize()
        end
        metadata = save_yearly_assimilation_fixture(root, table)
        metadata_path = joinpath(root, "scene_config_$(CONFIG_ID).toml")
        for change! in (m -> m["tables"]["plants"]["rows"] += 1,
            m -> m["tables"]["plants"]["complete"] = false,
            m -> m["plant_instance_identity_scope"] = "day",
            m -> m["config_id"] += 1,
            m -> push!(m["days"], first(m["days"])),
            m -> push!(m["scenes"][1]["scene"]["plant_rotations_rad"], 0.0),
            m -> m["tables"]["plants"]["files"][1]["sha256"] = repeat("0", 64))
            malformed = deepcopy(metadata)
            change!(malformed)
            open(metadata_path, "w") do io
                TOML.print(io, malformed)
            end
            @test_throws ArgumentError summarize()
        end
        save_yearly_assimilation_fixture(root, table; forcing=DataFrame(date=STAMPS .+ Minute(1)))
        @test_throws ArgumentError summarize()
        @test_throws ArgumentError summarize(; curve_sampling=:unsupported)
    end
end

end
