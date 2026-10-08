module AgripvYearSimulationTests

using Test
using Dates
using Random
using CSV
using DataFrames
using TOML
using SHA
import ..AgripvSceneTests

include(joinpath(@__DIR__, "..", "pvconfig.jl"))
include(joinpath(@__DIR__, "..", "year_simulation.jl"))

export YEAR_SIMULATION_TEST_RESULT

# Discovery only needs paired filenames; integration uses valid OBJ/MTG fixtures.
function write_dated_pair(directory, day; prefix="wheat")
    base = joinpath(directory, "$(prefix)_$(day)")
    write(base * ".obj", "# Filename discovery fixture\n")
    write(base * ".mtg", "# Filename discovery fixture\n")
    return (; day, obj_path=base * ".obj", mtg_path=base * ".mtg")
end

function with_dated_geometry(f)
    return mktempdir() do plant_dir
        for (day, ids) in ((Date(2025, 3, 4), [10, 20]),
            (Date(2025, 7, 2), [10, 20, 10_000_020]))
            base = joinpath(plant_dir, "wheat_$(day)")
            AgripvSceneTests.write_obj_fixture(base * ".obj", ids)
            AgripvSceneTests.write_mtg_fixture(base * ".mtg"; with_leaf=true)
        end
        return f(plant_dir)
    end
end

file_hash(path) = bytes2hex(SHA.sha256(read(path)))

function saved_snapshot(directory)
    return Dict(name => read(joinpath(directory, name)) for name in readdir(directory))
end

function assert_daily_rows(table, days, forcing; config_id)
    @test Set(table.day) == Set(days)
    @test all(==(config_id), table.config_id)
    @test all(row -> Date(row.datetime) == row.day, eachrow(table))
    @test all(row -> !ismissing(row.node_id), eachrow(table))
    @test allunique([(row.day, row.node_id, row.timestep) for row in eachrow(table)])
    for day in days
        expected_dates = [DateTime(row.date) for row in forcing if Date(row.date) == day]
        daily = filter(:day => ==(day), table)
        @test sort(unique(daily.timestep)) == collect(eachindex(expected_dates))
        @test sort(unique(daily.datetime)) == sort(expected_dates)
        @test nrow(daily) == length(unique(daily.node_id)) * length(expected_dates)
        @test all(row -> row.datetime == expected_dates[row.timestep], eachrow(daily))
    end
end

equal_output_value(actual::Real, expected::Real) =
    isapprox(actual, expected; rtol=1e-6, atol=1e-9, nans=true)
equal_output_value(actual, expected) = isequal(actual, expected)

function assert_day_equivalence(saved_period_day, standalone_table)
    buffer = IOBuffer()
    CSV.write(buffer, standalone_table)
    seekstart(buffer)
    expected = CSV.read(buffer, DataFrame; types=Dict(:datetime => DateTime))
    actual = DataFrames.select(saved_period_day, Not([:day, :config_id]))
    @test names(actual) == names(expected)
    @test nrow(actual) == nrow(expected)
    sort!(actual, [:node_id, :timestep])
    sort!(expected, [:node_id, :timestep])
    identities = (:node_id, :plant_id, :plant_instance_id, :object_id,
        :timestep, :datetime, :scale, :kind)
    for column in propertynames(expected)
        @testset "$column" begin
            if column in identities
                @test isequal(actual[!, column], expected[!, column])
            else
                @test all(pair -> equal_output_value(pair...),
                    zip(actual[!, column], expected[!, column]))
            end
        end
    end
end

const YEAR_SIMULATION_TEST_RESULT = @testset "Growth-period simulations follow plant dates" begin
    @testset "Discovery sorts pairs, preserves gaps and rejects ambiguous sources" begin
        mktempdir() do directory
            days = [Date(2025, 3, 10), Date(2025, 3, 4), Date(2025, 3, 5)]
            for day in days
                write_dated_pair(directory, day)
            end
            write(joinpath(directory, "undated_plant.obj"), "# Ignored undated OBJ\n")
            write(joinpath(directory, "panel_2025-03-06.mtl"), "# Not a plant OBJ\n")
            sources = plant_simulation_days(; plant_dir=directory)
            @test getproperty.(sources, :day) == sort(days)
            @test length(sources) == 3
            @test all(source -> isabspath(source.obj_path) && isabspath(source.mtg_path), sources)
            @test all(source -> source.mtg_path == first(splitext(source.obj_path)) * ".mtg", sources)

            absent_mtg = only(filter(source -> source.day == Date(2025, 3, 5), sources)).mtg_path
            rm(absent_mtg)
            @test_throws ArgumentError plant_simulation_days(; plant_dir=directory)
            write(absent_mtg, "# Restored discovery fixture\n")

            write_dated_pair(directory, Date(2025, 3, 4); prefix="another_crop")
            @test_throws ArgumentError plant_simulation_days(; plant_dir=directory)
            filtered = plant_simulation_days(; plant_dir=directory, plant_pattern="wheat_*.obj")
            @test getproperty.(filtered, :day) == sort(days)
            @test_throws ArgumentError plant_simulation_days(; plant_dir=directory, plant_pattern="absent_*.obj")
        end
    end

    @testset "Two full days retain changing geometry and reset plant totals" begin
        with_dated_geometry() do plant_dir
            days = [Date(2025, 3, 4), Date(2025, 7, 2)]
            sources = plant_simulation_days(; plant_dir)
            expected_sources = Dict(source.day => source for source in sources if source.day in days)
            @test Set(keys(expected_sources)) == Set(days)
            forcing = get_meteo(days)
            @test all(day -> count(row -> Date(row.date) == day, forcing) == 24, days)
            config_id = 7302
            # Two plants make the second Plant node shift when the first plant
            # gains an organ, while a coarse ground grid bounds the raster workload.
            config = ConfigPV(; panel_length=1.0, panel_width=1.0,
                panel_height=2.0, panel_x_distance=2.0, panel_y_distance=2.0)
            scene_kwargs = (; plant_density=1.0, ground_res=2)

            @test_throws ArgumentError prepare_day_simulation(;
                pvconfig=config, day=first(days), meteo=forcing, scene_kwargs)

            mktempdir() do output_dir
                Random.seed!(7302)
                result = year_simulation(; compact_light=false, pvconfig=config, config_id, plant_dir,
                    days=reverse(days), meteo=forcing, scene_kwargs, output_dir)
                @test result.days == days
                @test all(isfile, values(result.paths))
                @test sort(readdir(output_dir)) == sort(basename.(collect(values(result.paths))))
                tables = (; (role => CSV.read(getproperty(result.paths, role), DataFrame;
                    types=Dict(:day => Date, :datetime => DateTime))
                    for role in (:leaves, :plants, :light))...)

                for role in (:leaves, :plants, :light)
                    table = getproperty(tables, role)
                    @test nrow(table) == getproperty(result.rows, role)
                    assert_daily_rows(table, days, forcing; config_id)
                end
                @test nrow(tables.plants) == 96
                @test nrow(tables.leaves) == 96
                @test count(==(last(days)), tables.light.day) ==
                    count(==(first(days)), tables.light.day) + 48
                @test count(row -> row.day == last(days) && isequal(row.kind, "senescent_leaf"),
                    eachrow(tables.light)) == 48
                @test all(isfinite, tables.leaves.A)
                @test all(isfinite, tables.light.Ri_PAR_f)
                @test all(isfinite, tables.plants.assimilation_step)
                @test all(isfinite, tables.plants.transpiration_step)

                # Planting identities survive regenerated daily scenes, whereas
                # node IDs retain their existing meaning within each scene.
                daily_plant_ids = Dict{Date,Dict{Int,Int}}()
                for day in days
                    daily = filter(:day => ==(day), tables.plants)
                    daily_plant_ids[day] = Dict(zip(daily.plant_instance_id, daily.plant_id))
                end
                @test all(ids -> Set(keys(ids)) == Set([2, 3]), values(daily_plant_ids))
                @test daily_plant_ids[first(days)][3] != daily_plant_ids[last(days)][3]
                @test tables.plants.node_id == tables.plants.plant_id
                for role in (:leaves, :light)
                    for row in eachrow(getproperty(tables, role))
                        if ismissing(row.plant_id)
                            @test ismissing(row.plant_instance_id)
                        else
                            @test row.plant_id == daily_plant_ids[row.day][row.plant_instance_id]
                        end
                    end
                end
                @test Set(tables.leaves.plant_instance_id) == Set([2, 3])
                @test any(ismissing, tables.light.plant_instance_id)

                for daily_plant in groupby(tables.plants, [:day, :plant_id])
                    ordered = sort(DataFrame(daily_plant), :timestep)
                    for (step, cumulative) in ((:assimilation_step, :assimilation_cumulative),
                        (:transpiration_step, :transpiration_cumulative))
                        @test first(ordered[!, cumulative]) ≈ first(ordered[!, step])
                        @test last(ordered[!, cumulative]) ≈ sum(ordered[!, step])
                        @test ordered[!, cumulative] ≈ cumsum(ordered[!, step])
                    end
                end

                metadata = TOML.parsefile(result.paths.metadata)
                @test metadata["simulation"] == "growth_period"
                @test metadata["config_id"] == config_id
                @test metadata["days"] == string.(days)
                @test metadata["identity_scope"] == "day"
                @test metadata["plant_instance_identity_scope"] == "configuration"
                @test metadata["cumulative_scope"] == "day"
                @test length(metadata["scenes"]) == 2
                recipes = getindex.(metadata["scenes"], "scene")
                @test getindex.(recipes, "day") == string.(days)
                @test first(recipes)["plant_rotations_rad"] == last(recipes)["plant_rotations_rad"]
                @test length(first(recipes)["plant_rotations_rad"]) == 2
                @test first(metadata["scenes"])["scene_sha256"] != last(metadata["scenes"])["scene_sha256"]
                for (day, recipe) in zip(days, recipes)
                    @test recipe["config"] == Dict(string(name) => getproperty(config, name)
                        for name in propertynames(config))
                    @test recipe["plant_density"] == 1.0
                    @test recipe["ground_res"] == 2
                    for family in ("obj", "mtg")
                        expected = getproperty(expected_sources[day], Symbol(family * "_path"))
                        @test basename(recipe[family * "_path"]) == basename(expected)
                        @test normpath(joinpath(_agripv_project_root(), recipe[family * "_path"])) == expected
                        @test recipe[family * "_sha256"] == file_hash(expected)
                    end
                end
                for role in (:leaves, :plants, :light)
                    saved = metadata["tables"][string(role)]
                    @test saved["rows"] == getproperty(result.rows, role)
                    @test saved["file"] == basename(getproperty(result.paths, role))
                    @test saved["sha256"] == file_hash(getproperty(result.paths, role))
                end

                @testset "Yearly outputs match standalone daily weather and coupled solves" begin
                    for (index, day) in enumerate(days)
                        daily_forcing = TableOperations.filter(row -> Date(row.date) == day, forcing) |>
                            rows -> TimeStepTable(rows, PlantMeteo.metadata(forcing))
                        source = expected_sources[day]
                        matching_scene = merge(scene_kwargs, (
                            obj_path=source.obj_path, mtg_path=source.mtg_path,
                            plant_rotations=recipes[index]["plant_rotations_rad"],
                        ))
                        # Exercise the daily driver's own climate loading, while
                        # the yearly solve above slices a multi-date forcing table.
                        standalone = day_simulation(; pvconfig=config, day,
                            scene_kwargs=matching_scene)
                        @test agripv_scene_fingerprint(standalone.scene) ==
                            metadata["scenes"][index]["scene_sha256"]
                        @test [DateTime(row.date) for row in standalone.meteo] ==
                            [DateTime(row.date) for row in daily_forcing]
                        for role in (:leaves, :plants, :light)
                            @testset "$role on $day" begin
                                saved_day = filter(:day => ==(day), getproperty(tables, role))
                                assert_day_equivalence(saved_day, getproperty(standalone, role))
                            end
                        end
                    end
                end

                # Preflight failures must leave the successful configuration intact.
                before = saved_snapshot(output_dir)
                @test_throws ArgumentError year_simulation(; compact_light=false, pvconfig=config, config_id,
                    plant_dir, days, meteo=get_meteo(first(days)), scene_kwargs, output_dir)
                @test saved_snapshot(output_dir) == before
                @test_throws ArgumentError year_simulation(; compact_light=false, pvconfig=config, config_id,
                    plant_dir, days=[Date(2024, 1, 1)], meteo=forcing, scene_kwargs, output_dir)
                @test saved_snapshot(output_dir) == before
                @test_throws ArgumentError year_simulation(; compact_light=false, pvconfig=config, config_id,
                    plant_dir, days=Date[], meteo=forcing, scene_kwargs, output_dir)
                @test saved_snapshot(output_dir) == before

                # The first day is staged before a malformed second-day MTG fails.
                second_mtg = expected_sources[last(days)].mtg_path
                original_mtg = read(second_mtg)
                try
                    write(second_mtg, "Deliberately invalid MTG file\n")
                    @test_throws Exception year_simulation(; compact_light=false, pvconfig=config, config_id,
                        plant_dir, days, meteo=forcing, scene_kwargs, output_dir)
                    @test saved_snapshot(output_dir) == before
                finally
                    write(second_mtg, original_mtg)
                end

                # Exercise the default compact yearly writer and publication cleanup.
                first_hour = TimeStepTable([first(forcing)], PlantMeteo.metadata(forcing))
                compact = year_simulation(; pvconfig=config, config_id, plant_dir,
                    days=days[1:1], meteo=first_hour, scene_kwargs, output_dir)
                @test endswith(compact.paths.light, ".csv.gz")
                @test !isfile(result.paths.light)
                compact_table = _agripv_open_light(compact.paths.light) do io
                    CSV.read(io, DataFrame)
                end
                @test propertynames(compact_table) == AGRIPV_LIGHT_EXPORT_COLUMNS
                @test nrow(compact_table) == compact.rows.light
                @test all(==(DateTime(first(forcing).date)), compact_table.datetime)
                @test all(!ismissing, compact_table.Ra_PAR_f)

                # A one-step rerun checks selective retention and stale CSV cleanup
                # without repeating the two complete simulated days.
                first_hour = TimeStepTable([first(forcing)], PlantMeteo.metadata(forcing))
                summary = year_simulation(; compact_light=false, pvconfig=config, config_id, plant_dir,
                    days=days[1:1], meteo=first_hour, scene_kwargs, output_dir,
                    keep_leaves=false, keep_light=false)
                @test summary.paths.leaves === nothing
                @test summary.paths.light === nothing
                @test summary.rows.leaves == 0
                @test summary.rows.light == 0
                @test summary.rows.plants == 2
                @test isfile(summary.paths.plants)
                @test !isfile(result.paths.leaves)
                @test !isfile(result.paths.light)
                @test sort(readdir(output_dir)) == sort(basename.([summary.paths.plants, summary.paths.metadata]))
                summary_metadata = TOML.parsefile(summary.paths.metadata)
                @test Set(keys(summary_metadata["tables"])) == Set(["plants"])
                @test summary_metadata["days"] == string.(days[1:1])
            end
        end
    end
end

end # module AgripvYearSimulationTests
