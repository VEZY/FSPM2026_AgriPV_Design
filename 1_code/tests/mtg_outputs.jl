module AgripvMTGOutputTests

using Test
using Dates
using DataFrames
using PlantSimEngine
using MultiScaleTreeGraph
import ..AgripvOutputTests

export MTG_OUTPUT_TEST_RESULT

# Reuse the existing prescribed publishers: this suite exercises identity,
# output conversions and attachment, without adding a physiological model.
const OT = AgripvOutputTests

function mtg_output_fixture(; plant_ids=true)
    attrs(; geometry=nothing, kind=nothing, plantID=nothing) = Dict{Symbol,Any}(
        :Id => 7, :geometry => geometry, :kind => kind, :plantID => plantID,
    )
    mtg = Node(11, NodeMTG("/", :Scene, 1, 0), attrs())
    plant_a = Node(23, mtg, NodeMTG("+", :Plant, 1, 1),
        attrs(; plantID=plant_ids ? 1 : nothing))
    stem = Node(29, plant_a, NodeMTG("/", :Stem, 1, 2), attrs())
    leaf_a = Node(47, stem, NodeMTG("+", :LeafSection, 1, 3),
        attrs(; geometry=:prescribed_mesh, kind=:active_leaf))
    plant_b = Node(101, mtg, NodeMTG("+", :Plant, 2, 1),
        attrs(; plantID=plant_ids ? 2 : nothing))
    leaf_b = Node(203, plant_b, NodeMTG("/", :LeafSection, 1, 2),
        attrs(; geometry=:prescribed_mesh, kind=:active_leaf))
    senescent = Node(257, plant_b, NodeMTG("+", :LeafSection, 2, 2),
        attrs(; geometry=:prescribed_mesh, kind=:senescent_leaf))
    ground = Node(509, mtg, NodeMTG("+", :Ground, 1, 1),
        attrs(; geometry=:prescribed_mesh))
    dates = [DateTime(2025, 7, 2, 6), DateTime(2025, 7, 2, 6, 30)]
    meteo = [(date=dates[i], duration=Minute(30), λ=λ)
        for (i, λ) in enumerate((2.5e6, 2.0e6))]
    initial_status(node) = node === leaf_a ?
        Status(A=8f0, area=0.25f0, λE=100f0) : node === leaf_b ?
        Status(A=-6f0, area=0.75f0, λE=-50f0) : Status()
    model = CompositeModel(
        mtg;
        id=node -> Symbol(:engine_, MultiScaleTreeGraph.node_id(node)),
        status=initial_status,
        applications=(
            ModelSpec(OT.AgriPVOutputTestLight(); name=:archimed_light,
                on=Many(scale=(:LeafSection, :Ground))),
            ModelSpec(OT.AgriPVOutputTestEnergy(); name=:energy_balance,
                on=Many(scale=:LeafSection, kind=:active_leaf)),
            ModelSpec(OT.AgriPVOutputTestSparse(); name=:plant_test,
                on=Many(scale=:Plant)),
        ),
        environment=meteo,
    )
    requests = vcat(OT.leaf_output_requests(), OT.light_output_requests(), [
        OutputRequest(Many(scale=:Plant), :sparse_value;
            application=:plant_test, name=:plant_test_value),
    ])
    simulation = PlantSimEngine.run!(model; steps=2, outputs=requests)
    leaves = OT.collect_leaf_outputs(simulation, model; meteo)
    # The production collector preserves native query order. Normalize this
    # small test table solely for the prescribed vector expectations below.
    sort!(leaves, [:node_id, :timestep])
    light = OT.collect_light_outputs(simulation, model; dates)
    plants = OT.collect_selected_outputs(simulation, model;
        scale=:Plant, dates, columns=(plant_value=(:plant_test, :sparse_value),))
    return (; mtg, plant_a, plant_b, stem, leaf_a, leaf_b, senescent, ground,
        model, simulation, meteo, dates, leaves, light, plants)
end

function nodes_by_id(mtg)
    nodes = Dict{Int,typeof(mtg)}()
    MultiScaleTreeGraph.traverse!(mtg) do node
        nodes[MultiScaleTreeGraph.node_id(node)] = node
    end
    return nodes
end

function snapshot_values(mtg, variables)
    return Dict(id => Tuple(node[name] for name in variables)
        for (id, node) in nodes_by_id(mtg))
end

const MTG_OUTPUT_TEST_RESULT = @testset "Wide MTG outputs and scalar visualization snapshots" begin
    @testset "Source identities, ancestry and publisher selection" begin
        f = mtg_output_fixture()
        @test f.leaves.node_id == [47, 47, 203, 203]
        @test f.leaves.object_id == [:engine_47, :engine_47, :engine_203, :engine_203]
        @test f.leaves.plant_id == [23, 23, 101, 101]
        @test f.leaves.plant_instance_id == [1, 1, 2, 2]
        @test eltype(f.leaves.plant_instance_id) == Union{Missing,Int}
        @test f.leaves.timestep == [1, 2, 1, 2]
        @test f.leaves.datetime == repeat(f.dates; outer=2)
        @test all(==(:active_leaf), f.leaves.kind)
        @test Set(f.light.node_id) == Set([47, 203, 257, 509])
        @test all(ismissing, f.light.plant_id[findall(id -> isequal(id, 509), f.light.node_id)])
        @test all(ismissing, f.light.plant_instance_id[findall(id -> isequal(id, 509), f.light.node_id)])
        @test all(==(101), f.light.plant_id[findall(id -> isequal(id, 257), f.light.node_id)])
        @test all(==(2), f.light.plant_instance_id[findall(id -> isequal(id, 257), f.light.node_id)])
        @test Set(f.plants.node_id) == Set([23, 101])
        @test f.plants.plant_id == f.plants.node_id
        @test Dict(zip(f.plants.node_id, f.plants.plant_instance_id)) == Dict(23 => 1, 101 => 2)
        for row in eachrow(f.leaves)
            matching_light = filter(light_row -> light_row.node_id == row.node_id &&
                light_row.timestep == row.timestep, f.light)
            @test only(matching_light.plant_instance_id) == row.plant_instance_id
        end
        @test f.leaf_a[:Id] == f.leaf_b[:Id] == 7
        @test source_node(f.model, :engine_47) === f.leaf_a
        @test source_node(f.model, :engine_203) === f.leaf_b
        @test length(OT.AGRIPV_LEAF_OUTPUT_COLUMNS) == 12
        @test all(name -> name in propertynames(f.leaves), keys(OT.AGRIPV_LEAF_OUTPUT_COLUMNS))
        @test f.leaves.aPPFD == Float32[1, 2, 1, 2]
        @test f.leaves.A == Float32[10, 12, -4, -2]

        # Leaf requests alone must retain all light columns on active leaves.
        g = mtg_output_fixture()
        leaf_only = PlantSimEngine.run!(g.model; steps=2, outputs=OT.leaf_output_requests())
        leaf_only_table = OT.collect_leaf_outputs(leaf_only, g.model; meteo=g.meteo)
        sort!(leaf_only_table, [:node_id, :timestep])
        @test leaf_only_table.Ra_SW_f == fill(7f0, 4)
        @test leaf_only_table.node_id == [47, 47, 203, 203]

        generic = OT.agripv_output_test_scene(; steps=1)
        generic_table = OT.collect_leaf_outputs(generic.simulation, generic.model)
        @test all(ismissing, generic_table.node_id)
        @test all(ismissing, generic_table.plant_id)
        @test all(ismissing, generic_table.plant_instance_id)

        # Unannotated MTGs still expose their daily node identity but cannot
        # acquire a persistent planting identity from a node ID or OBJ Id.
        unannotated = mtg_output_fixture(; plant_ids=false)
        @test all(ismissing, unannotated.leaves.plant_instance_id)
        @test all(ismissing, unannotated.plants.plant_instance_id)
        @test all(ismissing, unannotated.light.plant_instance_id)
        @test unannotated.leaves.plant_id == [23, 23, 101, 101]
        for invalid_id in (0, "plant_1")
            f.plant_a[:plantID] = invalid_id
            @test_throws ArgumentError OT.collect_leaf_outputs(f.simulation, f.model)
        end
    end

    @testset "Surface, latent heat, signed exchanges and actual durations" begin
        f = mtg_output_fixture()
        @test f.leaves.area == Float32[0.25, 0.25, 0.75, 0.75]
        @test f.leaves.A_section ≈ [2.5, 3.0, -3.0, -1.5]
        @test f.leaves.assimilation_step ≈ [4500.0, 5400.0, -5400.0, -2700.0]
        @test f.leaves.net_water_flux ≈ [1e-5, 1.25e-5, -1.5e-5, -1.875e-5]
        @test f.leaves.transpiration_flux ≈ [4e-5, 5e-5, 0.0, 0.0]
        @test f.leaves.transpiration ≈ [1e-5, 1.25e-5, 0.0, 0.0]
        @test f.leaves.condensation ≈ [0.0, 0.0, 1.5e-5, 1.875e-5]
        @test f.leaves.transpiration_step ≈ [0.018, 0.0225, 0.0, 0.0]
        @test f.leaves.net_water_flux ≈ f.leaves.transpiration .- f.leaves.condensation

        # PSE's execution clock requires uniform durations. Independently
        # exercise the conversion kernel's period/seconds contract and global
        # lookup on prescribed rows in reverse step order.
        table = DataFrame(timestep=[2, 1], A=[20.0, -4.0],
            area=[0.25, 0.75], λE=[100.0, -50.0])
        meteo = [(λ=2.5e6, duration=Minute(30)), (λ=2e6, duration=900.0)]
        @test OT._add_leaf_flux_outputs!(table, meteo) === table
        @test table.A_section ≈ [5.0, -3.0]
        @test table.assimilation_step ≈ [4500.0, -5400.0]
        @test table.net_water_flux ≈ [1.25e-5, -1.5e-5]
        @test table.transpiration_flux ≈ [5e-5, 0.0]
        @test table.transpiration ≈ [1.25e-5, 0.0]
        @test table.condensation ≈ [0.0, 1.5e-5]
        @test table.transpiration_step ≈ [0.01125, 0.0]
        plain = DataFrame(timestep=[2], A=[1.0], area=[1.0], λE=[1.0])
        @test_throws ArgumentError OT._add_leaf_flux_outputs!(plain, meteo[1:1])
        @test propertynames(plain) == [:timestep, :A, :area, :λE]
        @test_throws DomainError OT._add_leaf_flux_outputs!(plain,
            [(λ=2e6, duration=Minute(30)), (λ=0.0, duration=900.0)])
        @test_throws DomainError OT._add_leaf_flux_outputs!(plain,
            [(λ=2e6, duration=Minute(30)), (λ=2e6, duration=0.0)])
    end

    @testset "Snapshots attach to exact nodes and clear only selected variables" begin
        f = mtg_output_fixture()
        nodes = nodes_by_id(f.mtg)
        for node in values(nodes)
            node[:A] = -999.0
            node[:Ri_PAR_f] = -999.0
            node[:unrelated] = :preserved
            node[:timestep] = :metadata_preserved
            node[:plant_instance_id] = :metadata_preserved
        end
        @test OT.attach_outputs!(f.mtg, f.leaves; timestep=1) === f.mtg
        @test f.leaf_a[:A] == 10f0
        @test f.leaf_b[:A] == -4f0
        @test f.leaf_a[:transpiration_step] ≈ 0.018
        @test all(id -> isnothing(nodes[id][:A]), (11, 23, 29, 101, 257, 509))
        @test all(node -> node[:unrelated] == :preserved, values(nodes))
        @test all(node -> node[:timestep] == :metadata_preserved, values(nodes))
        @test all(node -> node[:plant_instance_id] == :metadata_preserved, values(nodes))

        OT.attach_outputs!(f.mtg, f.leaves; timestep=2, variables=[:A])
        @test f.leaf_a[:A] == 12f0
        @test f.leaf_b[:A] == -2f0
        @test f.leaf_a[:transpiration_step] ≈ 0.018
        OT.attach_outputs!(f.mtg, f.light; timestep=2, variables=[:Ri_PAR_f])
        @test all(id -> nodes[id][:Ri_PAR_f] == 1f0, (47, 203, 257, 509))
        @test all(id -> isnothing(nodes[id][:Ri_PAR_f]), (11, 23, 29, 101))
        @test f.leaf_a[:A] == 12f0

        f.ground[:A] = 123.0
        OT.attach_outputs!(f.mtg, f.leaves; timestep=1, variables=[:A], clear=false)
        @test f.ground[:A] == 123.0
        @test f.leaf_a[:A] == 10f0

        # Plant summaries belong on Plant nodes, even without geometry.
        OT.attach_outputs!(f.mtg, f.plants; timestep=2)
        @test f.plant_a[:plant_value] == 2
        @test f.plant_b[:plant_value] == 2
        @test isnothing(f.leaf_a[:plant_value])
        @test all(node -> node[:plant_instance_id] == :metadata_preserved, values(nodes))

        # Leaf and plant tables share flux names. Preserve both node scales
        # explicitly when assembling several tables on the same MTG.
        plant_fluxes = DataFrame(node_id=[23, 101], timestep=[1, 1],
            transpiration=[1e-5, 0.0])
        OT.attach_outputs!(f.mtg, plant_fluxes; timestep=1, clear=false)
        @test f.plant_a[:transpiration] ≈ 1e-5
        @test f.plant_b[:transpiration] == 0.0
        @test f.leaf_a[:transpiration] ≈ 1e-5
        @test f.leaf_b[:transpiration] == 0.0

        clone = deepcopy(f.mtg)
        OT.attach_outputs!(clone, f.leaves; timestep=2, variables=[:A])
        @test nodes_by_id(clone)[47][:A] == 12f0
        @test f.leaf_a[:A] == 10f0
        @test Set(keys(nodes_by_id(clone))) == Set(keys(nodes))

        unavailable = DataFrame(node_id=[47, 203, 257, 509], timestep=ones(Int, 4),
            display_value=Union{Missing,Float64}[missing, NaN, Inf, -Inf])
        OT.attach_outputs!(f.mtg, unavailable; timestep=1)
        @test all(node -> isnothing(node[:display_value]), values(nodes))
    end

    @testset "Invalid snapshots are rejected before any mutation" begin
        f = mtg_output_fixture()
        for node in values(nodes_by_id(f.mtg))
            node[:A] = -999.0
            node[:Ra_PAR_f] = -888.0
        end
        before = snapshot_values(f.mtg, (:A, :Ra_PAR_f))
        # Put the bad ID after a valid selected row to catch partial writes.
        bad_row = findfirst(row -> row.node_id == 203 && row.timestep == 1,
            eachrow(f.leaves))
        unknown = copy(f.leaves)
        unknown.node_id[bad_row] = 9999
        missing_id = copy(f.leaves)
        missing_id.node_id[bad_row] = missing
        repeated = vcat(f.leaves, f.leaves[1:1, :])
        invalid = [
            (table=DataFrame(timestep=[1], A=[1.0]), timestep=1, variables=[:A]),
            (table=DataFrame(node_id=[47], A=[1.0]), timestep=1, variables=[:A]),
            (table=f.leaves, timestep=99, variables=[:A]),
            (table=f.leaves, timestep=1, variables=Symbol[]),
            (table=f.leaves, timestep=1, variables=[:node_id]),
            (table=f.leaves, timestep=1, variables=[:plant_instance_id]),
            (table=f.leaves, timestep=1, variables=[:unretained]),
            (table=unknown, timestep=1, variables=[:A, :Ra_PAR_f]),
            (table=missing_id, timestep=1, variables=[:A, :Ra_PAR_f]),
            (table=repeated, timestep=1, variables=[:A, :Ra_PAR_f]),
        ]
        for case in invalid
            @test_throws ArgumentError OT.attach_outputs!(f.mtg, case.table;
                timestep=case.timestep, variables=case.variables)
            @test isequal(snapshot_values(f.mtg, (:A, :Ra_PAR_f)), before)
        end
        # Other timesteps do not affect the selected snapshot's validity.
        @test OT.attach_outputs!(f.mtg, unknown; timestep=2, variables=[:A]) === f.mtg
        @test f.leaf_a[:A] == 12f0 && f.leaf_b[:A] == -2f0
    end
end

end # module AgripvMTGOutputTests
