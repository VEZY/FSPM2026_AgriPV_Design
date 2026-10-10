module AgripvDailyPlottingTests

using Test, DataFrames, Dates, TOML
include(joinpath(@__DIR__, "..", "daily_plotting.jl"))

const DAILY_PLOTTING_TEST_RESULT = @testset "Saved daily plotting contracts" begin
    day = Date(2025, 7, 2)
    table = DataFrame(config_id=[0, 0, 1, 1], plant_id=[10, 20, 30, 40],
        datetime=fill(DateTime(day), 4), assimilation_step=[-2.0, 6.0, 10.0, 30.0])
    means = daily_config_mean(table, :assimilation_step)
    @test means.config_id == [0, 1]
    @test means.value_mean == [2.0, 20.0]
    @test table.assimilation_step[1] == -2.0

    snapshot = filter(:config_id => ==(0), table)
    @test _validate_plot_plant_series(snapshot, :assimilation_step) === snapshot
    @test_throws ArgumentError _validate_plot_plant_series(
        vcat(snapshot, snapshot[1:1, :]), :assimilation_step)
    incomplete = vcat(snapshot, DataFrame(config_id=[0], plant_id=[10],
        datetime=[DateTime(day) + Hour(1)], assimilation_step=[2.0]))
    @test_throws ArgumentError _validate_plot_plant_series(incomplete, :assimilation_step)
    invalid = copy(snapshot)
    invalid.assimilation_step[1] = NaN
    @test_throws ArgumentError _validate_plot_plant_series(invalid, :assimilation_step)

    @test _output_plot_range(DataFrame(timestep=[1, 1], A=[0.0, 0.0]), :A, 1) == (0.0, 1.0)
    @test _output_plot_range(DataFrame(timestep=[1, 1], A=[-2.0, 6.0]), :A, 1) == (-2.0, 6.0)
    @test _agripv_plot_hours([DateTime(day) + Hour(1), DateTime(day) + Minute(90)], day) == [1.0, 1.5]

    # The energy conversion uses the saved interval, including unequal subhour steps.
    radiation = DataFrame(plant_id=[10, 10],
        datetime=[DateTime(day), DateTime(day) + Minute(30)], absorbed_PAR_W=[2.0, 3.0])
    forcing = DataFrame(datetime=reverse(radiation.datetime), duration_s=[1800.0, 900.0])
    energy = _attach_saved_step_energy!(copy(radiation), forcing)
    @test energy.duration_s == [900.0, 1800.0]
    @test energy.absorbed_PAR_J == [1800.0, 5400.0]
    @test_throws ArgumentError _attach_saved_step_energy!(copy(radiation), forcing[1:1, :])
    @test_throws ArgumentError _attach_saved_step_energy!(copy(radiation), vcat(forcing, forcing[1:1, :]))
    invalid_forcing = copy(forcing)
    invalid_forcing.duration_s[1] = 0.0
    @test_throws ArgumentError _attach_saved_step_energy!(copy(radiation), invalid_forcing)
    @test_throws ArgumentError _plot_saved_day_durations(Dict(), day, ".")

    # A prescribed table tests the persistence contract; no simulation is run.
    mktempdir() do directory
        data_dir = joinpath(directory, "plants")
        persisted = DataFrame(node_id=[10, 20], plant_id=[10, 20], timestep=[1, 1],
            datetime=fill(DateTime(day), 2), scale=fill("Plant", 2), kind=fill(missing, 2),
            assimilation_step=[-2.0, 6.0])
        entries = _agripv_write_parquet(persisted, data_dir; day)
        for entry in entries
            entry["file"] = joinpath("plants", entry["file"])
        end
        metadata = Dict("config_id" => 0, "format_version" => 2,
            "scene" => Dict("day" => string(day)),
            "tables" => Dict("plants" => _agripv_parquet_info(entries)))
        filename = joinpath(directory, "scene_config_0_$(day).toml")
        write_metadata() = open(io -> TOML.print(io, metadata), filename, "w")
        write_metadata()
        loaded = load_plot_day_table(; config_id=0, day, input_dir=directory,
            variables=(:assimilation_step,))
        @test loaded.assimilation_step == [-2.0, 6.0]
        @test loaded.datetime == fill(DateTime(day), 2)
        @test_throws ArgumentError load_plot_day_table(;
            config_id=0, day=day + Day(1), input_dir=directory)
        entries[1]["rows"] += 1
        write_metadata()
        @test_throws ArgumentError load_plot_day_table(; config_id=0, day, input_dir=directory)
        entries[1]["rows"] -= 1
        entries[1]["sha256"] = "invalid-checksum"
        write_metadata()
        @test_throws ArgumentError load_plot_day_table(; config_id=0, day, input_dir=directory)
    end
end

end
