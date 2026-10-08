module AgripvSavedSimulationTests

using Test
using Dates
using Random
using SHA
using TOML
using CSV
using DataFrames
using MultiScaleTreeGraph
using PlantGeom
using GeometryBasics
import ..AgripvSceneTests

include(joinpath(@__DIR__, "..", "pvconfig.jl"))
include(joinpath(@__DIR__, "..", "scene.jl"))
include(joinpath(@__DIR__, "..", "simulation_outputs.jl"))
include(joinpath(@__DIR__, "..", "saved_simulation.jl"))

export SAVED_SIMULATION_TEST_RESULT

file_hash(path) = bytes2hex(SHA.sha256(read(path)))

function nearest_plant_id(node)
    while !isnothing(node)
        MultiScaleTreeGraph.symbol(node) == :Plant && return node_id(node)
        node = parent(node)
    end
    return missing
end

function nearest_plant_instance_id(node)
    while !isnothing(node)
        MultiScaleTreeGraph.symbol(node) == :Plant && return node[:plantID]
        node = parent(node)
    end
    return missing
end

function output_kind(node)
    MultiScaleTreeGraph.symbol(node) == :LeafSection || return missing
    return node[:state] == "senescent" ? :senescent_leaf : :active_leaf
end

# Prescribed values exercise persistence only; no radiation or physiology is run.
function prescribed_saved_tables(scene, day)
    light = DataFrame(
        node_id=Int[], plant_id=Union{Missing,Int}[],
        plant_instance_id=Union{Missing,Int}[], timestep=Int[],
        datetime=DateTime[], object_id=Int[], scale=Symbol[],
        kind=Union{Missing,Symbol}[], area=Float64[],
        Ri_PAR_f=Float64[], Ra_PAR_f=Float64[], aPPFD=Float64[],
    )
    areas = PlantGeom.node_areas(scene)
    geometry_nodes = sort(AgripvSceneTests.geometry_nodes(scene.mtg); by=node_id)
    for node in geometry_nodes, step in 1:2
        id = node_id(node)
        push!(light, (
            id, nearest_plant_id(node), nearest_plant_instance_id(node),
            step, DateTime(day) + Hour(step - 1),
            id, MultiScaleTreeGraph.symbol(node), output_kind(node), areas[id],
            100.0 + step + 0.01 * id, 50.0 + step, 150.0 + step,
        ))
    end
    leaves = filter(row -> row.scale == :LeafSection && row.kind == :active_leaf, light)
    leaves[!, :A] = [row.timestep == 1 ? 10.0 : -1.0 for row in eachrow(leaves)]
    leaves[!, :Tₗ] = fill(25.0, nrow(leaves))
    leaves[!, :Gₛ] = fill(0.2, nrow(leaves))
    leaves[!, :λE] = fill(100.0, nrow(leaves))
    plants = DataFrame(
        node_id=Int[], plant_id=Union{Missing,Int}[],
        plant_instance_id=Union{Missing,Int}[], timestep=Int[],
        datetime=DateTime[], object_id=Int[], scale=Symbol[],
        kind=Union{Missing,Symbol}[], A_plant=Float64[],
    )
    plant_nodes = sort(AgripvSceneTests.nodes_with_symbol(scene.mtg, :Plant); by=node_id)
    for node in plant_nodes, step in 1:2
        id = node_id(node)
        push!(plants, (id, id, node[:plantID], step, DateTime(day) + Hour(step - 1),
            id, :Plant, missing, 2.0 * step))
    end
    return (; leaves, plants, light)
end

function with_saved_fixture(f)
    return mktempdir() do directory
        obj_path = AgripvSceneTests.write_obj_fixture(joinpath(directory, "plant.obj"), [10, 20])
        mtg_path = AgripvSceneTests.write_mtg_fixture(joinpath(directory, "plant.mtg"); with_leaf=true)
        day = Date(2025, 7, 2)
        config_id = 52
        config = ConfigPV(; panel_length=1.0, panel_width=1.0,
            panel_height=2.0, panel_x_distance=2.0, panel_y_distance=2.0)
        Random.seed!(1234)
        scene = agripv_scene(; c=config, day, plant_density=1.0, ground_res=2,
            obj_path, mtg_path)
        tables = prescribed_saved_tables(scene, day)
        result = (; scene, tables...)
        output_dir = joinpath(directory, "saved")
        paths = write_day_outputs(result; config_id, output_dir)
        return f((; scene, result, config, config_id, day, paths,
            output_dir, obj_path, mtg_path))
    end
end

function geometry_snapshot(scene)
    return (
        points=Tuple.(GeometryBasics.coordinates(scene.merged_mesh)),
        faces=Tuple.(GeometryBasics.faces(scene.merged_mesh)),
        face2node=copy(scene.face2node),
        areas=PlantGeom.node_areas(scene),
        domain=scene.scene_xy_bounds,
    )
end

function change_metadata(f, update)
    original = read(f.paths.metadata)
    try
        metadata = TOML.parsefile(f.paths.metadata)
        update(metadata)
        open(f.paths.metadata, "w") do io
            TOML.print(io, metadata)
        end
        return load_day_outputs(; f.config_id, f.day, f.output_dir)
    finally
        write(f.paths.metadata, original)
    end
end

function change_csv_with_matching_hash(f, role, update)
    path = getproperty(f.paths, role)
    original_csv = read(path)
    original_metadata = read(f.paths.metadata)
    try
        table = update(CSV.read(path, DataFrame))
        CSV.write(path, table)
        metadata = TOML.parsefile(f.paths.metadata)
        metadata["tables"][string(role)]["sha256"] = file_hash(path)
        open(f.paths.metadata, "w") do io
            TOML.print(io, metadata)
        end
        return load_day_outputs(; f.config_id, f.day, f.output_dir)
    finally
        write(path, original_csv)
        write(f.paths.metadata, original_metadata)
    end
end

const SAVED_SIMULATION_TEST_RESULT = @testset "Saved daily outputs reconstruct their exact scene" begin
    @testset "Geometry, placements, values and visualization survive a fresh load" begin
        with_saved_fixture() do f
            recipe = f.scene.mtg[:agripv_scene_recipe]
            metadata = TOML.parsefile(f.paths.metadata)
            @test all(isfile, values(f.paths))
            @test length(AgripvSceneTests.nodes_with_symbol(f.scene.mtg, :Plant)) == 2
            @test metadata["format_version"] == 1
            @test metadata["config_id"] == f.config_id
            @test metadata["scene_sha256"] == agripv_scene_fingerprint(f.scene)
            @test metadata["scene"]["plant_rotations_rad"] == recipe["plant_rotations_rad"]
            @test all(source -> metadata["scene"][source * "_sha256"] ==
                file_hash(getproperty(f, Symbol(source * "_path"))), ("obj", "mtg"))

            Random.seed!(9999)
            loaded = load_day_outputs(; f.config_id, f.day, f.output_dir)
            @test loaded.day == f.day
            @test Tuple(getproperty(loaded.config, name) for name in fieldnames(ConfigPV)) ==
                Tuple(getproperty(f.config, name) for name in fieldnames(ConfigPV))
            @test agripv_scene_fingerprint(loaded.scene) == agripv_scene_fingerprint(f.scene)
            @test geometry_snapshot(loaded.scene) == geometry_snapshot(f.scene)
            @test loaded.scene.mtg[:agripv_scene_recipe]["plant_rotations_rad"] == recipe["plant_rotations_rad"]
            Random.seed!(42)
            again = load_day_outputs(; f.config_id, f.day, f.output_dir)
            @test agripv_scene_fingerprint(again.scene) == agripv_scene_fingerprint(f.scene)
            @test again.scene.mtg[:agripv_scene_recipe]["plant_rotations_rad"] == recipe["plant_rotations_rad"]
            for role in (:leaves, :plants, :light)
                @test isequal(getproperty(loaded, role), getproperty(f.result, role))
            end
            @test all(value -> value isa Symbol, loaded.light.scale)
            @test all(==(:active_leaf), loaded.leaves.kind)
            @test any(ismissing, loaded.light.kind)
            @test Set(loaded.light.node_id) == Set(keys(loaded.scene.nodes))
            @test Set(loaded.plants.plant_instance_id) == Set([2, 3])
            mtg_geometry_nodes = Dict(node_id(node) => node for node in
                AgripvSceneTests.geometry_nodes(loaded.scene.mtg))
            @test all(row -> isequal(row.plant_instance_id,
                nearest_plant_instance_id(mtg_geometry_nodes[row.node_id])),
                eachrow(loaded.light))

            attach_outputs!(loaded.scene.mtg, loaded.light; timestep=2, variables=[:Ri_PAR_f])
            expected_light = Dict(row.node_id => row.Ri_PAR_f for row in eachrow(loaded.light)
                if row.timestep == 2)
            @test all(node -> node[:Ri_PAR_f] == expected_light[node_id(node)],
                AgripvSceneTests.geometry_nodes(loaded.scene.mtg))
            attach_outputs!(loaded.scene.mtg, loaded.leaves; timestep=2, variables=[:A])
            @test all(node -> node[:A] == -1.0,
                AgripvSceneTests.nodes_with_symbol(loaded.scene.mtg, :LeafSection))
            @test all(node -> isnothing(node[:A]), filter(node ->
                MultiScaleTreeGraph.symbol(node) != :LeafSection,
                AgripvSceneTests.geometry_nodes(loaded.scene.mtg)))
            @test agripv_scene_fingerprint(loaded.scene) == metadata["scene_sha256"]
        end
    end

    @testset "A caller can load only the requested table" begin
        with_saved_fixture() do f
            loaded = load_day_outputs(; f.config_id, f.day, f.output_dir, tables=(:light,))
            @test ncol(loaded.leaves) == 0
            @test ncol(loaded.plants) == 0
            @test isequal(loaded.light, f.result.light)
            @test agripv_scene_fingerprint(loaded.scene) == agripv_scene_fingerprint(f.scene)
            @test_throws ArgumentError load_day_outputs(;
                f.config_id, f.day, f.output_dir, tables=(:unsupported,))
        end
    end

    @testset "Legacy daily tables do not require the added planting identity" begin
        with_saved_fixture() do f
            for role in (:leaves, :plants, :light)
                loaded = change_csv_with_matching_hash(f, role,
                    table -> DataFrames.select(table, Not(:plant_instance_id)))
                @test :plant_instance_id ∉ propertynames(getproperty(loaded, role))
                @test isequal(getproperty(loaded, role),
                    DataFrames.select(getproperty(f.result, role), Not(:plant_instance_id)))
                @test agripv_scene_fingerprint(loaded.scene) == agripv_scene_fingerprint(f.scene)
            end
        end
    end

    @testset "Changed sources, CSVs and metadata cannot silently load" begin
        with_saved_fixture() do f
            for path in (f.obj_path, f.mtg_path)
                original = read(path)
                try
                    open(path, "a") do io
                        write(io, "\n# Modified after saving\n")
                    end
                    @test_throws ArgumentError load_day_outputs(; f.config_id, f.day, f.output_dir)
                finally
                    write(path, original)
                end
            end
            original_csv = read(f.paths.leaves)
            try
                open(f.paths.leaves, "a") do io
                    write(io, "\n")
                end
                @test_throws ArgumentError load_day_outputs(; f.config_id, f.day, f.output_dir)
            finally
                write(f.paths.leaves, original_csv)
            end
            original_metadata = read(f.paths.metadata)
            try
                rm(f.paths.metadata)
                @test_throws ArgumentError load_day_outputs(; f.config_id, f.day, f.output_dir)
            finally
                write(f.paths.metadata, original_metadata)
            end
            @test_throws ArgumentError change_metadata(f, metadata -> metadata["config_id"] = 999)
            @test_throws ArgumentError change_metadata(f,
                metadata -> metadata["scene"]["day"] = "2025-07-03")
            @test_throws ArgumentError change_metadata(f,
                metadata -> metadata["scene_sha256"] = repeat("0", 64))
        end
    end

    @testset "Matching CSV hashes cannot hide inconsistent node identities" begin
        with_saved_fixture() do f
            @test_throws ArgumentError change_csv_with_matching_hash(f, :leaves,
                table -> vcat(table, table[1:1, :]))
            @test_throws ArgumentError change_csv_with_matching_hash(f, :leaves, table -> begin
                table.node_id[1] = maximum(keys(f.scene.nodes)) + 1000
                table
            end)
            @test_throws ArgumentError change_csv_with_matching_hash(f, :leaves, table -> begin
                table.plant_id[1] = node_id(f.scene.mtg)
                table
            end)
            for role in (:leaves, :plants, :light)
                @test_throws ArgumentError change_csv_with_matching_hash(f, role, table -> begin
                    table.plant_instance_id[1] = 999
                    table
                end)
            end
            @test_throws ArgumentError change_csv_with_matching_hash(f, :light, table -> begin
                row = findfirst(ismissing, table.plant_instance_id)
                @test !isnothing(row)
                table.plant_instance_id[row] = 1
                table
            end)
        end
    end
end

end # module AgripvSavedSimulationTests
