if !isdefined(@__MODULE__, :AgripvPlantBalance)
    include(joinpath(@__DIR__, "..", "plant_balance.jl"))
end

module AgripvPlantBalanceTests

using Test
using Dates
using PlantSimEngine
using ..AgripvPlantBalance

function direct_status(model; areas, assimilation, temperatures, latent_heat)
    return Status(;
        PlantSimEngine.outputs_(model)...,
        leaf_areas=areas,
        leaf_assimilation=assimilation,
        leaf_temperatures=temperatures,
        leaf_latent_heat=latent_heat,
        previous_assimilation=model.initial_assimilation,
        previous_transpiration=model.initial_transpiration,
    )
end

const KERNEL_TEST_RESULT = @testset "Plant flux units, area weighting, signed exchanges, and empty leaves" begin
    for T in (Float64, Float32)
        model = PlantBalance(initial_assimilation=T(5), initial_transpiration=T(0.1))
        status = direct_status(model;
            areas=T[0.25, 0.75, 0],
            assimilation=T[20, -4, -Inf],
            temperatures=T[20, 30, -Inf],
            latent_heat=T[100, -50, -Inf],
        )
        environment = (λ=T(2.5e6), duration=Hour(1))
        PlantSimEngine.run!(model, status, environment, nothing, nothing)
        @test status.leaf_area ≈ T(1)
        @test status.A_plant ≈ T(2)
        @test status.assimilation_step ≈ T(7200)
        @test status.assimilation_cumulative ≈ T(7205)
        @test status.Tₗ_mean ≈ T(27.5)
        @test status.Tₗ_min ≈ T(20)
        @test status.Tₗ_max ≈ T(30)
        @test status.transpiration ≈ T(1e-5)
        @test status.condensation ≈ T(1.5e-5)
        @test status.net_water_flux ≈ T(-5e-6)
        @test status.transpiration_step ≈ T(0.036)
        @test status.transpiration_cumulative ≈ T(0.136)
        @test status.A_plant isa T
        @test status.transpiration_cumulative isa T

        PlantSimEngine.run!(model, status, (λ=T(2.5e6), duration=Minute(30)), nothing, nothing)
        @test status.assimilation_step ≈ T(3600)
        @test status.transpiration_step ≈ T(0.018)
        PlantSimEngine.run!(model, status, (λ=T(2.5e6), duration=T(900)), nothing, nothing)
        @test status.assimilation_step ≈ T(1800)
        @test status.transpiration_step ≈ T(0.009)

        # With no green sections, cumulative quantities retain their baseline.
        empty_status = direct_status(model;
            areas=T[], assimilation=T[], temperatures=T[], latent_heat=T[],
        )
        PlantSimEngine.run!(model, empty_status, environment, nothing, nothing)
        @test empty_status.leaf_area == zero(T)
        @test empty_status.A_plant == zero(T)
        @test empty_status.transpiration_step == zero(T)
        @test empty_status.assimilation_cumulative == T(5)
        @test empty_status.transpiration_cumulative == T(0.1)
        @test all(isnan, (empty_status.Tₗ_mean, empty_status.Tₗ_min, empty_status.Tₗ_max))

        # Reject mismatched selections, invalid surfaces, and invalid forcing.
        bad_lengths = direct_status(model;
            areas=T[1], assimilation=T[], temperatures=T[20], latent_heat=T[100],
        )
        @test_throws DimensionMismatch PlantSimEngine.run!(model, bad_lengths, environment, nothing, nothing)
        bad_area = direct_status(model;
            areas=T[-1], assimilation=T[10], temperatures=T[20], latent_heat=T[100],
        )
        @test_throws DomainError PlantSimEngine.run!(model, bad_area, environment, nothing, nothing)
        @test_throws DomainError PlantSimEngine.run!(model, status, (λ=zero(T), duration=Hour(1)), nothing, nothing)
        @test_throws DomainError PlantSimEngine.run!(model, status, (λ=T(2.5e6), duration=Second(0)), nothing, nothing)
    end
end

PlantSimEngine.@process "prescribed_agripv_section" verbose=false

struct PrescribedSection <: AbstractPrescribed_Agripv_SectionModel end

PlantSimEngine.inputs_(::PrescribedSection) = (
    given_area=Required(Real), given_assimilation=Required(Real),
    given_temperature=Required(Real), given_latent_heat=Required(Real),
)
PlantSimEngine.outputs_(::PrescribedSection) = (area=0.0, A=0.0, Tₗ=0.0, λE=0.0)
PlantSimEngine.environment_inputs_(::PrescribedSection) = NamedTuple()
PlantSimEngine.environment_outputs_(::PrescribedSection) = NamedTuple()
PlantSimEngine.variable_contracts_(::PrescribedSection) = (
    area=AgripvPlantBalance.LEAF_AREA_CONTRACT,
)

function PlantSimEngine.run!(::PrescribedSection, status, environment, constants, context)
    status.area = status.given_area
    status.A = status.given_assimilation
    status.Tₗ = status.given_temperature
    status.λE = status.given_latent_heat
    return nothing
end

function prescribed_scenario(model=PlantBalance())
    section_status(area, A, temperature, latent_heat) = Status(
        given_area=area, given_assimilation=A,
        given_temperature=temperature, given_latent_heat=latent_heat,
    )
    return CompositeModel(
        Object(:scene; scale=:Scene),
        Object(:plant_1; scale=:Plant, parent=:scene),
        Object(:plant_2; scale=:Plant, parent=:scene),
        Object(:plant_empty; scale=:Plant, parent=:scene),
        Object(:leaf_a; scale=:LeafSection, kind=:active_leaf, parent=:plant_1,
            status=section_status(0.25, 20.0, 20.0, 100.0)),
        Object(:leaf_b; scale=:LeafSection, kind=:active_leaf, parent=:plant_1,
            status=section_status(0.75, -4.0, 30.0, -50.0)),
        Object(:dead_leaf; scale=:LeafSection, kind=:senescent_leaf, parent=:plant_1,
            status=section_status(10.0, 1e6, 200.0, 1e6)),
        Object(:other_plant_leaf; scale=:LeafSection, kind=:active_leaf, parent=:plant_2,
            status=section_status(0.5, 10.0, 25.0, 200.0));
        applications=(
            ModelSpec(PrescribedSection(); name=:leaf_source, on=Many(scale=:LeafSection)),
            plant_balance_spec(model; light_application=:leaf_source, energy_application=:leaf_source),
        ),
        environment=(λ=2.5e6, duration=Hour(1)),
    )
end

const SCENARIO_TEST_RESULT = @testset "Plant subtree isolation and previous-timestep accumulation" begin
    scene = prescribed_scenario()
    simulation = PlantSimEngine.run!(scene; steps=3, outputs=:none)
    p1 = final_state(simulation, One(id=:plant_1))
    p2 = final_state(simulation, One(id=:plant_2))
    empty_plant = final_state(simulation, One(id=:plant_empty))
    @test p1.leaf_area ≈ 1.0
    @test p1.A_plant ≈ 2.0
    @test p1.assimilation_cumulative ≈ 3 * 7200
    @test p1.transpiration_cumulative ≈ 3 * 0.036
    @test p1.Tₗ_mean ≈ 27.5
    @test p2.leaf_area ≈ 0.5
    @test p2.A_plant ≈ 5.0
    @test p2.assimilation_cumulative ≈ 3 * 18000
    @test p2.transpiration_cumulative ≈ 3 * 0.144
    @test empty_plant.leaf_area == 0.0
    @test isnan(empty_plant.Tₗ_mean)
    @test empty_plant.assimilation_cumulative == 0.0
    @test empty_plant.transpiration_cumulative == 0.0

    continue!(simulation; steps=1)
    continued = final_state(simulation, One(id=:plant_1))
    @test continued.assimilation_cumulative ≈ 4 * 7200
    @test continued.transpiration_cumulative ≈ 4 * 0.036

    # A fresh scenario does not inherit a previous simulation's running totals.
    fresh = PlantSimEngine.run!(prescribed_scenario(); steps=1, outputs=:none)
    @test final_state(fresh, One(id=:plant_1)).assimilation_cumulative ≈ 7200
    baseline = PlantSimEngine.run!(prescribed_scenario(
        PlantBalance(initial_assimilation=100.0, initial_transpiration=0.5));
        steps=2, outputs=:none)
    @test final_state(baseline, One(id=:plant_1)).assimilation_cumulative ≈ 100 + 2 * 7200
    @test final_state(baseline, One(id=:plant_1)).transpiration_cumulative ≈ 0.5 + 2 * 0.036
end

end # module AgripvPlantBalanceTests
