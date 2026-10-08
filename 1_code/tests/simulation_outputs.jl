module AgripvOutputTests

using Test
using Dates
using DataFrames
using PlantSimEngine

include(joinpath(@__DIR__, "..", "simulation_outputs.jl"))

# PlantMeteo's prepared forcing uses timestamp subtypes of AbstractDateTime.
# Exercise that public date contract without adding a transitive dependency.
struct AgriPVOutputTestTimestamp <: Dates.AbstractDateTime
    value::DateTime
end
Dates.DateTime(value::AgriPVOutputTestTimestamp) = value.value

PlantSimEngine.@process "agripv_output_test_light" verbose=false
struct AgriPVOutputTestLight <: AbstractAgripv_Output_Test_LightModel end
PlantSimEngine.inputs_(::AgriPVOutputTestLight) = NamedTuple()
PlantSimEngine.outputs_(::AgriPVOutputTestLight) = (
    Ri_PAR_f=1f0, Ri_NIR_f=2f0, Ra_PAR_f=3f0, Ra_NIR_f=4f0,
    Ra_SW_f=7f0, aPPFD=0f0, area=2f0, sky_fraction=0.5f0,
)
function PlantSimEngine.run!(::AgriPVOutputTestLight, status, environment, constants, context)
    status.aPPFD += 1f0
    return nothing
end

PlantSimEngine.@process "agripv_output_test_energy" verbose=false
struct AgriPVOutputTestEnergy <: AbstractAgripv_Output_Test_EnergyModel end
PlantSimEngine.inputs_(::AgriPVOutputTestEnergy) = NamedTuple()
PlantSimEngine.outputs_(::AgriPVOutputTestEnergy) = (A=0f0, Tₗ=25f0, Gₛ=0.2f0, λE=100f0)
function PlantSimEngine.run!(::AgriPVOutputTestEnergy, status, environment, constants, context)
    status.A += 2f0
    return nothing
end

PlantSimEngine.@process "agripv_output_test_sparse" verbose=false
struct AgriPVOutputTestSparse <: AbstractAgripv_Output_Test_SparseModel end
PlantSimEngine.inputs_(::AgriPVOutputTestSparse) = NamedTuple()
PlantSimEngine.outputs_(::AgriPVOutputTestSparse) = (sparse_value=0,)
function PlantSimEngine.run!(::AgriPVOutputTestSparse, status, environment, constants, context)
    status.sparse_value += 1
    return nothing
end

function agripv_output_test_scene(; outputs=:all, steps=4)
    dates = [DateTime(2025, 7, 2, hour) for hour in (0, 1, 4, 8)]
    model = CompositeModel(
        Object(:scene; scale=:Scene),
        Object(10; scale=:LeafSection, kind=:active_leaf, parent=:scene, geometry=:test_mesh),
        Object(2; scale=:LeafSection, kind=:active_leaf, parent=:scene, geometry=:test_mesh),
        Object(3; scale=:LeafSection, kind=:senescent_leaf, parent=:scene, geometry=:test_mesh),
        Object(4; scale=:Panel, parent=:scene, geometry=:test_mesh);
        applications=(
            ModelSpec(
                AgriPVOutputTestLight(); name=:archimed_light,
                on=Many(scale=(:LeafSection, :Panel)),
            ),
            ModelSpec(
                AgriPVOutputTestEnergy(); name=:energy_balance,
                on=Many(scale=:LeafSection, kind=:active_leaf),
            ),
            ModelSpec(
                AgriPVOutputTestSparse(); name=:sparse,
                on=Many(scale=:LeafSection, kind=:active_leaf), every=Hour(2),
            ),
        ),
        environment=[(date=date, duration=Hour(1)) for date in dates],
    )
    simulation = PlantSimEngine.run!(model; steps, outputs)
    return (; simulation, model, dates)
end

@testset "selected AgriPV outputs match the retained publications" begin
    (; simulation, model, dates) = agripv_output_test_scene()
    leaves = collect_leaf_outputs(simulation, model; dates)
    light = collect_light_outputs(simulation, model; dates)
    reference = collect_outputs(simulation; sink=nothing)

    @test nrow(leaves) == 8
    @test leaves.object_id == repeat([10, 2]; inner=4)
    @test leaves.timestep == repeat(1:4; outer=2)
    @test leaves.datetime == repeat(dates; outer=2)
    @test all(==(:LeafSection), leaves.scale)
    @test eltype(leaves.A) == Union{Missing,Float32}
    @test eltype(leaves.area) == Union{Missing,Float32}
    @test eltype(leaves.object_id) == Int
    @test all(ismissing, leaves.node_id)
    @test all(ismissing, leaves.plant_id)
    @test all(ismissing, leaves.plant_instance_id)
    @test nrow(light) == 16
    @test Set(light.object_id) == Set([10, 2, 3, 4])
    @test Set(light.scale) == Set([:LeafSection, :Panel])

    for (table, columns) in ((leaves, AGRIPV_LEAF_OUTPUT_COLUMNS), (light, AGRIPV_LIGHT_OUTPUT_COLUMNS))
        for (name, (application, variable)) in pairs(columns)
            oracle = Dict(
                (row.object_id, row.timestep) => row.value
                for row in reference
                if row.application_id == application && row.variable == variable
            )
            @test all(row -> isequal(row[name], oracle[(row.object_id, row.timestep)]), eachrow(table))
        end
    end
end

@testset "sparse outputs retain their actual cadence and source identity" begin
    (; simulation, model, dates) = agripv_output_test_scene()
    table = collect_selected_outputs(
        simulation, model;
        scale=:LeafSection, kind=:active_leaf, dates,
        columns=(light=(:archimed_light, :aPPFD), energy=(:energy_balance, :A), sparse=(:sparse, :sparse_value)),
    )
    @test isequal(table.sparse, repeat(Union{Missing,Int}[1, missing, 2, missing]; outer=2))
    @test table.light == repeat(Float32[1, 2, 3, 4]; outer=2)
    @test table.energy == repeat(Float32[2, 4, 6, 8]; outer=2)
    @test eltype(table.sparse) == Union{Missing,Int}
    @test table.datetime == repeat(dates; outer=2)
    @test_throws ArgumentError collect_selected_outputs(
        simulation, model; columns=(A=(:unretained_publisher, :A),), scale=:LeafSection,
    )
    @test_throws ArgumentError collect_selected_outputs(
        simulation, model; columns=(timestep=(:energy_balance, :A),),
    )
    @test_throws ArgumentError collect_selected_outputs(
        simulation, model; columns=(plant_instance_id=(:energy_balance, :A),),
    )
end

@testset "selected retention, dates, and empty targets" begin
    requests = vcat(leaf_output_requests(), light_output_requests())
    @test length(unique(request.name for request in requests)) == length(requests)
    (; simulation, model, dates) = agripv_output_test_scene(; outputs=requests)
    @test nrow(collect_leaf_outputs(simulation, model; dates)) == 8
    @test nrow(collect_light_outputs(simulation, model; dates)) == 16
    undated = collect_leaf_outputs(simulation, model)
    @test all(ismissing, undated.datetime)
    daily = collect_leaf_outputs(simulation, model; dates=Date(2025, 7, 2))
    @test all(==(DateTime(2025, 7, 2)), daily.datetime)
    timestamp_dates = collect_leaf_outputs(simulation, model; dates=AgriPVOutputTestTimestamp.(dates))
    @test timestamp_dates.datetime == repeat(dates; outer=2)
    singleton_timestamp = collect_leaf_outputs(simulation, model; dates=AgriPVOutputTestTimestamp(first(dates)))
    @test all(==(first(dates)), singleton_timestamp.datetime)
    invalid_dates = collect_leaf_outputs(simulation, model; dates=[2025, "2025-07-02", nothing, missing])
    @test all(ismissing, invalid_dates.datetime)
    one_row_dates = collect_leaf_outputs(simulation, model; dates=dates[1:1])
    @test isequal(one_row_dates.datetime, repeat(Union{Missing,DateTime}[dates[1], missing, missing, missing]; outer=2))
    partial_dates = collect_leaf_outputs(simulation, model; dates=dates[1:2])
    @test isequal(partial_dates.datetime, repeat(Union{Missing,DateTime}[dates[1], dates[2], missing, missing]; outer=2))
    empty = collect_selected_outputs(
        simulation, model; columns=(A=(:energy_balance, :A),), scale=:Absent,
    )
    @test nrow(empty) == 0
    @test names(empty) == ["node_id", "plant_id", "plant_instance_id", "timestep", "datetime", "object_id", "scale", "kind", "A"]
end

end # module AgripvOutputTests
