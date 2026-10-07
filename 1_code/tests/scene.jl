module AgripvSceneTests

using Test
using MultiScaleTreeGraph
using GeometryBasics
using PlantGeom

include(joinpath(@__DIR__, "..", "scene.jl"))

function write_obj_fixture(path, component_ids)
    # PlantGL's exported OBJ files put vertices first, then named objects.
    # Use disconnected triangles so object splitting cannot merge sections.
    open(path, "w") do io
        println(io, "# Minimal AgriPV regression fixture, coordinates in centimetres")
        for i in eachindex(component_ids)
            x = 300 * (i - 1)
            println(io, "v $x 0 0")
            println(io, "v $(x + 100) 0 0")
            println(io, "v $x 100 0")
        end
        for (i, id) in enumerate(component_ids)
            first_vertex = 3 * (i - 1) + 1
            println(io, "o vid_$id")
            println(io, "f $first_vertex $(first_vertex + 1) $(first_vertex + 2)")
        end
    end
    return path
end

function write_mtg_fixture(path; with_leaf)
    root = MultiScaleTreeGraph.Node(
        1, NodeMTG("/", "Plant", 1, 1), Dict(:Id => 1000),
    )
    stem = MultiScaleTreeGraph.Node(
        2, root, NodeMTG("/", "Stem", 1, 2), Dict(:Id => 10),
    )
    if with_leaf
        MultiScaleTreeGraph.Node(
            3, stem, NodeMTG("+", "Leaf", 1, 2), Dict(:Id => 20),
        )
    end
    MultiScaleTreeGraph.write_mtg(path, root)
    return path
end

function fixture_plant(component_ids; with_leaf=true)
    return mktempdir() do directory
        obj = write_obj_fixture(joinpath(directory, "plant.obj"), component_ids)
        mtg = write_mtg_fixture(joinpath(directory, "plant.mtg"); with_leaf)
        read_plant(obj, mtg)
    end
end

function nodes_with_symbol(root, expected)
    nodes = MultiScaleTreeGraph.Node[]
    MultiScaleTreeGraph.traverse!(root) do node
        MultiScaleTreeGraph.symbol(node) == expected && push!(nodes, node)
    end
    return nodes
end

function geometry_nodes(root)
    nodes = MultiScaleTreeGraph.Node[]
    MultiScaleTreeGraph.traverse!(root) do node
        isnothing(node[:geometry]) || push!(nodes, node)
    end
    return nodes
end

function assert_metre_triangle(geometry)
    mesh = PlantGeom.geometry_to_mesh(geometry)
    points = GeometryBasics.coordinates(mesh)
    @test length(GeometryBasics.faces(mesh)) == 1
    @test maximum(point[1] for point in points) - minimum(point[1] for point in points) ≈ 1.0
    @test maximum(point[2] for point in points) - minimum(point[2] for point in points) ≈ 1.0
end

const SCENE_TEST_RESULT = @testset "Imported plant geometry and active/senescent leaf sections" begin
    @testset "A stem is represented once and remains a stem" begin
        plant = fixture_plant([10]; with_leaf=false)
        stem = only(nodes_with_symbol(plant, :Stem))
        @test isempty(nodes_with_symbol(plant, :LeafSection))
        @test length(geometry_nodes(plant)) == 1
        @test stem[:geometry] isa PlantGeom.Geometry
        @test isnothing(stem[:state])
        assert_metre_triangle(stem[:geometry])
    end

    @testset "Green and senescent portions have distinct geometry and states" begin
        plant = fixture_plant([10, 20, 10_000_020])
        stem = only(nodes_with_symbol(plant, :Stem))
        leaf = only(nodes_with_symbol(plant, :Leaf))
        sections = nodes_with_symbol(plant, :LeafSection)
        @test length(sections) == 2
        @test sort([section[:state] for section in sections]) == ["active", "senescent"]
        @test length(geometry_nodes(plant)) == 3
        @test isnothing(leaf[:geometry])
        @test stem[:geometry] isa PlantGeom.Geometry
        active = only(filter(section -> section[:state] == "active", sections))
        senescent = only(filter(section -> section[:state] == "senescent", sections))
        @test MultiScaleTreeGraph.parent(active) === leaf
        @test MultiScaleTreeGraph.parent(senescent) === active
        @test active[:geometry] !== senescent[:geometry]
        @test active[:geometry].ref_mesh.name == "20"
        @test senescent[:geometry].ref_mesh.name == "10000020"
        assert_metre_triangle(active[:geometry])
        assert_metre_triangle(senescent[:geometry])
    end

    @testset "A fully senescent leaf needs no green OBJ mesh" begin
        plant = fixture_plant([10, 10_000_020])
        leaf = only(nodes_with_symbol(plant, :Leaf))
        section = only(nodes_with_symbol(plant, :LeafSection))
        @test section[:state] == "senescent"
        @test MultiScaleTreeGraph.parent(section) === leaf
        @test section[:geometry] isa PlantGeom.Geometry
        @test section[:geometry].ref_mesh.name == "10000020"
        @test length(geometry_nodes(plant)) == 2
        @test isnothing(leaf[:geometry])
        assert_metre_triangle(section[:geometry])
    end
end

end # module AgripvSceneTests
