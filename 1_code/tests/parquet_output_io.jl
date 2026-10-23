module AgripvParquetOutputTests
using Test, Dates, DataFrames, TOML, Random
import ..AgripvSavedSimulationTests
import ..AgripvYearSimulationTests
include(joinpath(@__DIR__, "..", "year_simulation.jl"))
include(joinpath(@__DIR__, "..", "attach_assimilation_to_scene.jl"))

@testset "Merged cycle assimilation sums signed plant steps" begin
    mktempdir() do root
        day = Date(2025, 3, 4)
        data = DataFrame(plant_instance_id=[1, 1, 1, 2],
            assimilation_step=[1e6, 2e6, -0.5e6, -1e6])
        files = _agripv_write_parquet(data, root; day, batch_rows=2)
        open(joinpath(root, "scene_config_0.toml"), "w") do io
            TOML.print(io, Dict("tables" => Dict("plants" => _agripv_parquet_info(files))))
        end
        totals = integrated_plant_assimilation(; config_id=0, output_dir=root)
        @test totals.plant_instance_id == [1, 2]
        @test totals.total_assimilation == [2.5, -1.0]
    end
end

@testset "Lossless Parquet storage and bounded readers" begin
    mktempdir() do root
        day = Date(2025, 3, 4)
        original = DataFrame(node_id=1:5, datetime=fill(DateTime(day), 5), day=fill(day, 5),
            timestep=fill(1, 5), scale=fill(:LeafSection, 5),
            kind=Union{Missing,Symbol}[:active_leaf, missing, :active_leaf, :active_leaf, missing],
            A=Union{Missing,Float64}[0.0, -0.0, missing, NaN, nextfloat(1.0)])
        entries = _agripv_write_parquet(original, root; day, batch_rows=2)
        @test length(entries) == 3
        @test maximum(x["rows"] for x in entries) <= 2
        info = _agripv_parquet_info(entries)
        @test info["compression_level"] == 19
        restored = _agripv_read_parquet(root, info)
        @test isequal(original.A, restored.A)
        @test restored.scale == string.(original.scale)
        @test restored.datetime == original.datetime
        @test isequal(DataFrames.select(_agripv_read_parquet(root, info; timestep=1, variables=:A), :A), DataFrames.select(restored, :A))
        metadata = Dict("config_id" => 0, "tables" => Dict("leaves" => info))
        open(joinpath(root, "scene_config_0.toml"), "w") do io
            TOML.print(io, metadata)
        end
        batches = Int[]
        rows = foreach_saved_output_batch(; config_id=0, table=:leaves, input_dir=root, columns=(:node_id,), batch_rows=1) do batch
            @test propertynames(batch) == [:node_id]
            push!(batches, nrow(batch))
        end
        @test rows == 5 && batches == fill(1, 5)
        count = with_saved_outputs(; config_id=0, tables=:leaves, input_dir=root) do con, _
            only(DataFrame(DBInterface.execute(con, "SELECT count(*) AS n FROM leaves")).n)
        end
        @test count == 5
        @test _agripv_with_db() do con
            all(==("ZSTD"), DataFrame(DBInterface.execute(con,
                "SELECT compression FROM parquet_metadata($(_agripv_sql_string(joinpath(root, entries[1]["file"]))))")).compression)
        end
        @test_throws ArgumentError _agripv_saved_files(root, merge(info, Dict("available" => false)))
        write(joinpath(root, entries[1]["file"]), "damaged")
        @test_throws ArgumentError _agripv_read_parquet(root, info)
    end
    mktempdir() do root
        empty = DataFrame(value=Float64[], datetime=DateTime[])
        entries = _agripv_write_parquet(empty, root; day=Date(2025, 3, 4))
        @test isequal(_agripv_read_parquet(root, _agripv_parquet_info(entries)), empty)
    end
end

@testset "Daily Parquet scene reload and snapshot selection" begin
    AgripvSavedSimulationTests.with_saved_fixture() do f
        paths = write_day_outputs(f.result; config_id=f.config_id, output_dir=f.output_dir, batch_rows=3)
        @test isdir(paths.light)
        metadata = TOML.parsefile(paths.metadata)
        @test metadata["format_version"] == 2
        loaded = load_day_outputs(; f.config_id, f.day, f.output_dir, tables=:light, timestep=2, variables=:Ra_PAR_f)
        @test all(==(2), loaded.light.timestep)
        @test :Ri_PAR_f ∉ propertynames(loaded.light)
        @test loaded.light.Ra_PAR_f == filter(:timestep => ==(2), f.result.light).Ra_PAR_f
        @test agripv_scene_fingerprint(loaded.scene) == metadata["scene_sha256"]
    end
end

@testset "Seeded Parquet period and radiation-only retention" begin
    AgripvYearSimulationTests.with_dated_geometry() do plant_dir
        day = Date(2025, 3, 4)
        forcing = get_meteo(day)
        hourly = TimeStepTable([forcing[13]], PlantMeteo.metadata(forcing))
        config = ConfigPV(; panel_length=1.0, panel_width=1.0, panel_height=2.0,
            panel_x_distance=2.0, panel_y_distance=2.0)
        settings = (; plant_density=1.0, ground_res=2)
        mktempdir() do parent
            a = year_simulation(; pvconfig=config, config_id=0, plant_dir, days=[day],
                meteo=hourly, scene_kwargs=settings, seed=123, output_dir=joinpath(parent, "a"))
            b = year_simulation(; pvconfig=config, config_id=0, plant_dir, days=[day],
                meteo=hourly, scene_kwargs=settings, seed=123, mode=:light, tables=(:light,), output_dir=joinpath(parent, "b"))
            ma, mb = TOML.parsefile(a.paths.metadata), TOML.parsefile(b.paths.metadata)
            @test Set(keys(mb["tables"])) == Set(["light"])
            @test ma["scenes"][1]["scene_sha256"] == mb["scenes"][1]["scene_sha256"]
            @test ma["reproducibility"]["seed"] == 123
            @test !ma["reproducibility"]["archived_rotations_reused"]
            la = _agripv_read_parquet(dirname(a.paths.metadata), ma["tables"]["light"])
            lb = _agripv_read_parquet(dirname(b.paths.metadata), mb["tables"]["light"])
            @test isequal(la, lb)
            @test ma["forcing_origin"] == "simulation"
            yearly = load_yearly_scene(; config_id=0, day, output_dir=dirname(a.paths.metadata))
            @test agripv_scene_fingerprint(yearly.scene) == ma["scenes"][1]["scene_sha256"]
            attached = attach_assimilation_to_yearly_scene(0, day; output_dir=dirname(a.paths.metadata))
            @test agripv_scene_fingerprint(attached) == ma["scenes"][1]["scene_sha256"]
            @test nrow(_agripv_read_parquet(dirname(a.paths.metadata), ma["forcing"])) == 1
            loaded = load_day_outputs(; config_id=0, day, output_dir=dirname(a.paths.metadata), tables=:leaves)
            @test all(isfinite, loaded.leaves.A)
            # A failed source preflight preserves the previously published sidecar.
            before = read(a.paths.metadata)
            @test_throws ArgumentError year_simulation(; pvconfig=config, config_id=0, plant_dir,
                days=[Date(2024, 1, 1)], scene_kwargs=settings, output_dir=dirname(a.paths.metadata))
            @test read(a.paths.metadata) == before
        end
    end
end
end
