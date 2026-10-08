module AgripvGeometrySelectorTests

using Test
using Dates
using DataFrames
using PlantSimEngine
using MultiScaleTreeGraph
import ..AgripvSceneTests

include(joinpath(@__DIR__, "..", "pvconfig.jl"))
include(joinpath(@__DIR__, "..", "simulation.jl"))
include(joinpath(@__DIR__, "..", "saved_simulation.jl"))

const GEOMETRY_SELECTOR_TEST_RESULT = @testset "Indexed radiation destinations preserve geometry and saved outputs" begin
    mktempdir() do directory
        obj_path = AgripvSceneTests.write_obj_fixture(
            joinpath(directory, "plant.obj"), [10, 20, 10_000_020],
        )
        mtg_path = AgripvSceneTests.write_mtg_fixture(
            joinpath(directory, "plant.mtg"); with_leaf=true,
        )
        # A structural LeafSection without a mesh must not acquire radiation
        # or physiology just because its botanical scale matches green leaves.
        plant = read_mtg(mtg_path, NodeMTG)
        leaf = only(AgripvSceneTests.nodes_with_symbol(plant, :Leaf))
        MultiScaleTreeGraph.addchild!(
            leaf, NodeMTG("/", :LeafSection, 99, 3),
            Dict{Symbol,Any}(:Id => 99, :state => "active"),
        )
        MultiScaleTreeGraph.write_mtg(mtg_path, plant)

        day = Date(2025, 7, 2)
        config = ConfigPV(; panel_length=1.0, panel_width=1.0,
            panel_height=2.0, panel_x_distance=2.0, panel_y_distance=2.0)
        setup = prepare_day_simulation(; pvconfig=config, day,
            scene_kwargs=(; plant_density=1.0, ground_res=2, obj_path, mtg_path))
        geometry_ids = Set(node_id(node) for node in
            AgripvSceneTests.geometry_nodes(setup.scene.mtg))
        active_ids = Set(node_id(node) for node in
            AgripvSceneTests.nodes_with_symbol(setup.scene.mtg, :LeafSection)
            if !isnothing(node[:geometry]) && node[:state] == "active")
        geometryless_sections = filter(node -> isnothing(node[:geometry]),
            AgripvSceneTests.nodes_with_symbol(setup.scene.mtg, :LeafSection))
        @test length(geometryless_sections) == 2

        compiled = PlantSimEngine.compile_composite_model(setup.coupled)
        radiation_binding = only(PlantSimEngine.explain_output_bindings(compiled))
        @test radiation_binding.application_id == :archimed_light
        @test radiation_binding.coverage == :exact
        @test Set(radiation_binding.destination_ids) == geometry_ids
        @test !haskey(PlantSimEngine.criteria(radiation_binding.selector), :id)
        applications = PlantSimEngine.explain_applications(compiled)
        for name in (:photosynthesis, :energy_balance, :stomatal_conductance)
            application = only(filter(row -> row.application_id == name, applications))
            @test Set(application.target_ids) == active_ids
        end
        geometryless_objects = filter(object -> isnothing(object.geometry),
            PlantSimEngine.model_objects(setup.coupled; scale=:LeafSection))
        @test length(geometryless_objects) == length(geometryless_sections)
        @test all(object -> isnothing(object.kind), geometryless_objects)

        requests = vcat(plant_output_requests(), leaf_output_requests(), light_output_requests())
        simulation = PlantSimEngine.run!(setup.coupled; steps=1, outputs=requests)
        dates = [row.date for row in setup.meteo]
        leaves = collect_leaf_outputs(simulation, setup.coupled; dates, meteo=setup.meteo)
        light = collect_light_outputs(simulation, setup.coupled; dates)
        plants = collect_plant_outputs(simulation, setup.coupled; dates)
        @test Set(light.node_id) == geometry_ids
        @test Set(leaves.node_id) == active_ids
        @test all(==(:active_leaf), leaves.kind)
        @test all(ismissing, light.kind[light.scale .!= :LeafSection])
        @test Set(skipmissing(light.kind)) == Set((:active_leaf, :senescent_leaf))
        @test Set(plants.plant_instance_id) == Set([2, 3])

        result = (; scene=setup.scene, leaves, light, plants)
        output_dir = joinpath(directory, "saved")
        write_day_outputs(result; config_id=91, output_dir)
        loaded = load_day_outputs(; config_id=91, day, output_dir)
        for role in (:leaves, :light, :plants)
            original = getproperty(result, role)
            restored = getproperty(loaded, role)
            @test isequal(restored.node_id, original.node_id)
            @test isequal(restored.kind, original.kind)
            @test isequal(restored.plant_instance_id, original.plant_instance_id)
        end
    end
end

end # module AgripvGeometrySelectorTests
