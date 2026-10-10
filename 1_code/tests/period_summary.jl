module AgripvPeriodSummaryTests
using Test, Dates, DataFrames, TOML, CSV
include(joinpath(@__DIR__, "..", "period_summary.jl"))

const DAYS = [Date(2025, 3, 4), Date(2025, 3, 5)]
const STAMPS = [DateTime(day) + Hour(hour) for day in DAYS for hour in (12, 13)]
const DURATIONS = [10.0, 20.0, 30.0, 40.0]

function period_fixture(; n_plants=2)
    identities = repeat(collect(1:n_plants); inner=4)
    assimilation = [1e6, -2e5, 3e5, 4e5]
    plants = DataFrame(node_id=100 .* identities, plant_instance_id=identities, datetime=repeat(STAMPS, n_plants),
        assimilation_step=vcat([assimilation .* id for id in 1:n_plants]...),
        # Deliberately unrelated daily-reset state; never used for the totals.
        assimilation_cumulative=fill(9e99, n_plants * 4),
        transpiration=identities .* 0.01,
        condensation=identities .* 0.002,
        net_water_flux=identities .* 0.008,
        transpiration_step=identities .* 0.01 .* repeat(DURATIONS, n_plants),
        leaf_area=identities .* repeat([0.0, 1.0, 2.0, 3.0], n_plants),
        Tₗ_mean=vcat([[NaN, 20.0, 30.0, 40.0] .+ 5 * (id - 1) for id in 1:n_plants]...),
        Tₗ_min=vcat([[NaN, 19.0, 29.0, 39.0] .+ 5 * (id - 1) for id in 1:n_plants]...),
        Tₗ_max=vcat([[NaN, 21.0, 31.0, 41.0] .+ 5 * (id - 1) for id in 1:n_plants]...))
    light = DataFrame(datetime=DateTime[], node_id=Int[], plant_id=Union{Missing,Int}[],
        plant_instance_id=Union{Missing,Int}[], scale=String[], kind=Union{Missing,String}[],
        Ra_PAR_f=Float64[], area=Float64[])
    for stamp in STAMPS
        for id in 1:n_plants
            # These three organs are all required for total plant PAR. Green
            # leaf only would yield 2 W, whereas total plant absorption is 28 W.
            for (organ, scale, kind, flux, area) in
                ((1, "LeafSection", "active_leaf", 2.0, 1.0),
                    (2, "LeafSection", "senescent_leaf", 5.0, 2.0),
                    (3, "StemSection", missing, 4.0, 4.0))
                push!(light, (stamp, 10 * id + organ, 100 * id, id, scale, kind, flux * id, area))
            end
        end
        # Soil and panel powers must not be divided by the planting population.
        push!(light, (stamp, 999, missing, missing, "Soil", missing, 1e9, 100.0))
        push!(light, (stamp, 998, missing, missing, "PV", missing, 1e9, 100.0))
    end
    allowmissing!(plants)
    return (; plants, light, forcing=DataFrame(date=STAMPS, duration=DURATIONS))
end

function save_period_fixture(root, fixture; config_id=73, directory="config_$config_id")
    function write_table(table, role)
        files = Dict{String,Any}[]
        stamp_column = role == "forcing" ? :date : :datetime
        for day in DAYS
            daily = filter(stamp_column => stamp -> Date(stamp) == day, table)
            day_directory = joinpath(directory, role, "day=$day")
            entries = _agripv_write_parquet(daily, joinpath(root, day_directory); day, batch_rows=13)
            for file in entries
                file["file"] = joinpath(day_directory, file["file"])
            end
            append!(files, entries)
        end
        return _agripv_parquet_info(files)
    end
    population = length(unique(skipmissing(fixture.plants.plant_instance_id)))
    metadata = Dict("config_id" => config_id, "simulation" => "growth_period",
        "plant_instance_identity_scope" => "configuration", "days" => string.(DAYS),
        "forcing_origin" => "reconstructed", "forcing_provenance" => "fixture reconstructed forcing",
        "scenes" => [Dict("scene" => Dict("day" => string(day),
            "plant_rotations_rad" => zeros(population), "plant_density" => 4.0,
            "config" => Dict("panel_x_distance" => 2.0, "panel_y_distance" => 2.0))) for day in DAYS],
        "tables" => Dict("plants" => write_table(fixture.plants, "plants"), "light" => write_table(fixture.light, "light")),
        "forcing" => write_table(fixture.forcing, "forcing"))
    open(joinpath(root, "scene_config_$config_id.toml"), "w") do io
        TOML.print(io, metadata)
    end
    return metadata
end

const PERIOD_SUMMARY_TEST_RESULT = @testset "Complete-period carbon, all-organ energy, water and intensive temperature" begin
    mktempdir() do root
        fixture = period_fixture()
        save_period_fixture(root, fixture)
        result = summarize_period_outputs(; config_id=73, input_dir=root)
        values = Dict(row.quantity => row for row in eachrow(result.table))
        @test nrow(result.table) == 7
        @test result.per_plant.plant_instance_id == [1, 2]
        @test values["net_assimilation"].total ≈ 4.5
        @test values["net_assimilation"].mean_per_plant ≈ 2.25
        @test values["absorbed_PAR"].total ≈ 28 * sum(DURATIONS) * 3
        @test values["absorbed_PAR"].mean_per_plant ≈ 4200
        @test values["transpiration"].total ≈ 3.0
        @test values["net_water_exchange"].total ≈ 2.4
        @test "condensation" ∉ keys(values)
        @test values["leaf_temperature_mean"].statistic_value ≈ (35 * 200 + 40 * 400) / 600
        @test values["leaf_temperature_min"].statistic_value == 19.0
        @test values["leaf_temperature_max"].statistic_value == 46.0
        @test ismissing(values["leaf_temperature_mean"].total)
        @test ismissing(values["leaf_temperature_mean"].mean_per_plant)
        @test all(==(2), result.table.n_plants)
        @test all(==(4.0), result.table.domain_area_m2)
        @test all(==(0.5), result.table.actual_density_plants_m2)
        @test all(==("reconstructed"), result.table.forcing_origin)
        @test all(==(4), result.table.n_steps)

        # Source ordering has no influence on the full-period aggregation.
        reordered = (; plants=reverse(fixture.plants), light=reverse(fixture.light), forcing=reverse(fixture.forcing))
        save_period_fixture(root, reordered)
        reordered_result = summarize_period_outputs(; config_id=73, input_dir=root)
        @test all(zip(reordered_result.table.total, result.table.total)) do (a, b)
            ismissing(a) ? ismissing(b) : isapprox(a, b)
        end
        @test isequal(reordered_result.table.statistic_value, result.table.statistic_value)

        # Leaf-free plants legitimately publish undefined temperature; these
        # cannot contaminate a weighted mean, and an entirely leaf-free period
        # must yield missing temperature statistics rather than zero degrees.
        leaf_free = deepcopy(fixture)
        leaf_free.plants.leaf_area .= 0
        leaf_free.plants.Tₗ_mean .= NaN
        leaf_free.plants.Tₗ_min .= NaN
        leaf_free.plants.Tₗ_max .= NaN
        save_period_fixture(root, leaf_free)
        zero_leaf = summarize_period_outputs(; config_id=73, input_dir=root)
        @test all(ismissing, zero_leaf.table.statistic_value)

        for change! in (f -> f.plants.plant_instance_id[end] = 9,
            f -> deleteat!(f.plants, 1),
            f -> f.plants.transpiration_step[1] = -1,
            f -> f.plants.transpiration_step[1] *= 2,
            f -> f.plants.net_water_flux[1] = Inf,
            f -> f.plants.Tₗ_mean[2] = NaN,
            f -> f.plants.Tₗ_min[2] = 25,
            f -> f.plants.leaf_area[2] = -1,
            f -> f.forcing.duration[1] = 0,
            f -> f.forcing.date[1] += Minute(1),
            f -> push!(f.forcing, f.forcing[1, :]),
            f -> f.light.Ra_PAR_f[1] = -1,
            f -> f.light.datetime[1] += Minute(1),
            f -> f.light.area[1] = NaN,
            f -> f.light.node_id[1] = 0,
            f -> f.light.plant_id[1] = 456,
            f -> f.light.plant_instance_id[1] = missing,
            f -> push!(f.light, f.light[1, :]),
            f -> deleteat!(f.light, 1))
            malformed = deepcopy(fixture)
            change!(malformed)
            save_period_fixture(root, malformed)
            @test_throws ArgumentError summarize_period_outputs(; config_id=73, input_dir=root)
        end

        # Actual populations may differ across designs; dividing each total by
        # its own validated population is required, and remains explicit.
        save_period_fixture(root, fixture)
        save_period_fixture(root, period_fixture(; n_plants=1); config_id=74)
        written = write_period_summary_tables(; config_ids=[73, 74], input_dir=root, summary_dir=joinpath(root, "summary"))
        @test !written.equal_populations
        @test written.comparison.n_plants == [2, 1]
        @test written.comparison.net_assimilation_mean_per_plant ≈ [2.25, 1.5]
        @test isfile(joinpath(written.summary_dir, "config_73.csv"))
        @test isfile(joinpath(written.summary_dir, "config_74.md"))
        @test occursin("Plant populations differ", read(joinpath(written.summary_dir, "config_73.md"), String))
        @test !TOML.parsefile(joinpath(written.summary_dir, "provenance.toml"))["equal_plant_populations"]
        @test nrow(CSV.read(joinpath(written.summary_dir, "config_73.csv"), DataFrame)) == 7
        @test_throws ArgumentError write_period_summary_tables(; config_ids=[73, 73], input_dir=root)
        @test_throws ArgumentError write_period_summary_tables(; config_ids=Int[], input_dir=root)
        # Pruning by the manifest's day index must reject a incorrectly labelled
        # shard, rather than quietly dropping or reassigning its organ values.
        metadata = save_period_fixture(root, fixture)
        metadata["tables"]["light"]["files"][1]["day"] = string(last(DAYS))
        open(joinpath(root, "scene_config_73.toml"), "w") do io
            TOML.print(io, metadata)
        end
        @test_throws ArgumentError summarize_period_outputs(; config_id=73, input_dir=root)
        save_period_fixture(root, fixture)
        mismatched = period_fixture(; n_plants=1)
        mismatched.forcing.duration[1] += 1
        mismatched.plants.transpiration_step[1] = mismatched.plants.transpiration[1] * mismatched.forcing.duration[1]
        save_period_fixture(root, mismatched; config_id=74)
        @test_throws ArgumentError write_period_summary_tables(; config_ids=[73, 74], input_dir=root)
    end
end
end
