module AgripvYearFaparTests

using Test, Dates, CSV, DataFrames, TOML, SHA
include(joinpath(@__DIR__, "..", "year_fapar.jl"))

export YEAR_FAPAR_TEST_RESULT

const CONFIG_ID = 73
const DAYS = [Date(2025, 3, 4), Date(2025, 7, 2)]

function fapar_fixture()
    stamps = [DateTime(DAYS[1]), DateTime(DAYS[1]) + Hour(12),
        DateTime(DAYS[1]) + Hour(13), DateTime(DAYS[2]) + Hour(12)]
    forcing = [(date=stamp, duration=duration, Ri_PAR_f=flux)
        for (stamp, duration, flux) in zip(stamps,
            [Hour(1), Minute(30), Hour(2), Hour(1)], [0.0, 100.0, 200.0, 50.0])]
    fluxes = ([0, 0, 0, 0, 0], [20, 5, 10, 30, 5],
        [40, 20, 20, 20, 10], [5, 5, 10, 5, 5])
    table = DataFrame(datetime=DateTime[], day=Date[], timestep=Int[], config_id=Int[],
        node_id=Int[], plant_id=Union{Missing,Int}[], scale=String[], kind=String[],
        Ra_PAR_f=Float64[], area=Float64[], Ri_PAR_f=Float64[])
    for (step, stamp) in enumerate(stamps), object in 1:5
        push!(table, (stamp, Date(stamp), step <= 3 ? step : 1, CONFIG_ID, object,
            object <= 3 ? 9 : missing,
            ["LeafSection", "LeafSection", "Stem", "Panel", "Cobblestone"][object],
            ["active_leaf", "senescent_leaf", "stem", "panel", "ground"][object],
            fluxes[step][object], [2.0, 1.0, 0.5, 3.0, 6.0][object], 3e9))
    end
    allowmissing!(table)
    return (; table, forcing)
end

function save_fixture(directory, table; rows=nrow(table), sha=nothing)
    filename = "light_config_$(CONFIG_ID).csv"
    path = joinpath(directory, filename)
    CSV.write(path, table)
    digest = bytes2hex(SHA.sha256(read(path)))
    metadata = Dict("simulation" => "growth_period", "config_id" => CONFIG_ID,
        "days" => string.(DAYS), "scenes" => [Dict("scene" => Dict("day" => string(day),
            "config" => Dict("panel_x_distance" => 2.0, "panel_y_distance" => 3.0,
                "panel_orientation" => 180.0))) for day in DAYS],
        "tables" => Dict("light" => Dict("file" => filename, "rows" => rows,
            "sha256" => isnothing(sha) ? digest : sha)))
    open(joinpath(directory, "scene_config_$(CONFIG_ID).toml"), "w") do io
        TOML.print(io, metadata)
    end
    return digest
end

const YEAR_FAPAR_TEST_RESULT = @testset "Yearly PAR capture uses energy and scene area" begin
    mktempdir() do directory
        (; table, forcing) = fapar_fixture()
        digest = save_fixture(directory, table)
        summarize(; kwargs...) = summarize_year_fapar(;
            config_id=CONFIG_ID, input_dir=directory, forcing, kwargs...)
        result = summarize(; batch_bytes=4096)
        hourly, daily = result.hourly, result.daily
        @test result.rows == 20
        @test result.source_sha256 == digest
        @test hourly.datetime == getproperty.(forcing, :date)
        @test hourly.timestep == [1, 2, 3, 1]
        @test hourly.duration_s == [3600, 1800, 7200, 3600]
        @test all(==(CONFIG_ID), hourly.config_id)
        @test daily.day == DAYS
        @test hourly.incoming_PAR_J == [0, 100 * 6 * 1800, 200 * 6 * 7200, 50 * 6 * 3600]
        @test hourly.apar_plants_J == [0, 50 * 1800, 110 * 7200, 20 * 3600]
        @test hourly.apar_panels_J == [0, 90 * 1800, 60 * 7200, 15 * 3600]
        @test hourly.apar_ground_J == [0, 30 * 1800, 60 * 7200, 30 * 3600]
        @test hourly.rows_plants == fill(3, 4)
        @test hourly.rows_panels == hourly.rows_ground == fill(1, 4)
        for output in (hourly, daily)
            @test output.apar_total_J == output.apar_plants_J + output.apar_panels_J + output.apar_ground_J
            lit = findall(value -> !ismissing(value), output.fapar_total)
            @test output.fapar_total[lit] ≈ output.fapar_plants[lit] + output.fapar_panels[lit] + output.fapar_ground[lit]
            @test isequal(output.nonabsorbed_fraction, 1 .- output.fapar_total)
        end
        @test all(ismissing, hourly[1, [:fapar_plants, :fapar_panels, :fapar_ground, :fapar_total]])
        @test ismissing(hourly.nonabsorbed_fraction[1])
        @test daily.fapar_total[1] ≈ (170 * 1800 + 230 * 7200) / (100 * 6 * 1800 + 200 * 6 * 7200)
        @test !isapprox(daily.fapar_total[1], (hourly.fapar_total[2] + hourly.fapar_total[3]) / 2)
        @test all(>(0), daily.nonabsorbed_fraction)
        @test all(<(1), daily.fapar_total)
        for batch_bytes in (1, 73, 157)
            batched = summarize(; batch_bytes)
            @test isequal(batched.hourly, hourly) && isequal(batched.daily, daily)
            @test batched.rows == result.rows && batched.source_sha256 == digest
        end
        tabular = summarize_year_fapar(; config_id=CONFIG_ID, input_dir=directory,
            forcing=DataFrame(forcing), batch_bytes=73)
        @test isequal(tabular.hourly, hourly) && isequal(tabular.daily, daily)

        # Compact export: each day's append is a separate gzip member.
        compact = copy(table)
        compact.plant_instance_id = [ismissing(id) ? missing : 1 for id in compact.plant_id]
        compressed_path = joinpath(directory, "light_config_$(CONFIG_ID).csv.gz")
        for day in DAYS
            chunk = _agripv_compact_light(filter(:day => ==(day), compact))
            CSV.write(compressed_path, chunk; compress=true, append=isfile(compressed_path))
        end
        compact_metadata = TOML.parsefile(joinpath(directory, "scene_config_$(CONFIG_ID).toml"))
        compact_metadata["tables"]["light"]["file"] = basename(compressed_path)
        compressed_hash = bytes2hex(open(SHA.sha256, compressed_path))
        compact_metadata["tables"]["light"]["sha256"] = compressed_hash
        open(joinpath(directory, "scene_config_$(CONFIG_ID).toml"), "w") do io
            TOML.print(io, compact_metadata)
        end
        for batch_bytes in (1, 73, 4096)
            compressed = summarize(; batch_bytes)
            @test isequal(compressed.hourly, hourly)
            @test isequal(compressed.daily, daily)
            @test compressed.rows == result.rows
            @test compressed.source_sha256 == compressed_hash
        end
        compact_metadata["tables"]["light"]["sha256"] = repeat("0", 64)
        open(joinpath(directory, "scene_config_$(CONFIG_ID).toml"), "w") do io
            TOML.print(io, compact_metadata)
        end
        @test_throws ArgumentError summarize(; batch_bytes=73)
        save_fixture(directory, table)

        # Refresh hashes after each corruption so validation checks actual rows.
        for change! in (t -> t.scale[4] = "Unknown", t -> t.scale[4] = missing,
            t -> t.Ra_PAR_f[1] = NaN,
            t -> t.area[1] = Inf, t -> t.Ra_PAR_f[1] = -1, t -> t.area[1] = -1,
            t -> t.Ra_PAR_f[1] = missing, t -> t.area[1] = missing,
            t -> t.datetime[1] = missing, t -> t.datetime[1] += Minute(1),
            t -> t.day[1] = DAYS[2], t -> t.timestep[1] = 2, t -> t.config_id[1] = 999)
            malformed = copy(table)
            change!(malformed)
            save_fixture(directory, malformed)
            @test_throws ArgumentError summarize(; batch_bytes=73)
        end
        save_fixture(directory, select(table, Not(:area)))
        @test_throws ArgumentError summarize()
        save_fixture(directory, table; rows=21)
        @test_throws ArgumentError summarize()
        save_fixture(directory, table; sha=repeat("0", 64))
        @test_throws ArgumentError summarize()
        @test isequal(summarize(; verify_hash=false).hourly, hourly)
        save_fixture(directory, table)
        @test_throws ArgumentError summarize(; batch_bytes=0)
        @test_throws ArgumentError summarize_year_fapar(; config_id=CONFIG_ID,
            input_dir=directory, forcing=vcat(forcing, forcing[1:1]))
    end
end

end # module AgripvYearFaparTests
