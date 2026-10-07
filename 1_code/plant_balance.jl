module AgripvPlantBalance

using Dates
using PlantSimEngine

export PlantBalance, plant_balance_spec, PLANT_BALANCE_OUTPUTS

PlantSimEngine.@process "plant_balance" verbose=false

# Match ArchimedLight 0.2's distributed `area` contract exactly.
const LEAF_AREA_CONTRACT = VariableContract(
    unit=:square_metre, basis=:organ, temporal=nothing,
    aggregation=:total, extent=:extensive,
)

const PLANT_AREA_CONTRACT = VariableContract(
    unit=:square_metre, basis=:plant, temporal=nothing,
    aggregation=:total, extent=:extensive,
)
const ASSIMILATION_RATE_CONTRACT = VariableContract(
    unit=:micromol_carbon_dioxide, basis=:plant, temporal=:second,
    aggregation=:rate, extent=:extensive,
)
const ASSIMILATION_STEP_CONTRACT = VariableContract(
    unit=:micromol_carbon_dioxide, basis=:plant, temporal=:timestep,
    aggregation=:total, extent=:extensive,
)
const ASSIMILATION_CUMULATIVE_CONTRACT = VariableContract(
    unit=:micromol_carbon_dioxide, basis=:plant, temporal=:instantaneous,
    aggregation=:state, extent=:extensive,
)
const WATER_RATE_CONTRACT = VariableContract(
    unit=:kilogram_water, basis=:plant, temporal=:second,
    aggregation=:rate, extent=:extensive,
)
const WATER_STEP_CONTRACT = VariableContract(
    unit=:kilogram_water, basis=:plant, temporal=:timestep,
    aggregation=:total, extent=:extensive,
)
const WATER_CUMULATIVE_CONTRACT = VariableContract(
    unit=:kilogram_water, basis=:plant, temporal=:instantaneous,
    aggregation=:state, extent=:extensive,
)

temperature_contract(aggregation) = VariableContract(
    unit=:degree_celsius, basis=:leaf_surface, temporal=:instantaneous,
    aggregation=aggregation, extent=:intensive,
)

"""
    PlantBalance(; initial_assimilation=0.0, initial_transpiration=0.0)

Aggregate the simulated green leaf sections of each plant on ArchimedLight's
represented mesh surface area (m²). `A_plant` is net assimilation (μmol CO₂ s⁻¹);
`assimilation_step` and `assimilation_cumulative` are μmol CO₂ per timestep and
since simulation start. Negative assimilation is retained.

`Tₗ_mean` is area weighted; `Tₗ_min` and `Tₗ_max` are extrema over positive-area
sections (°C). All three are NaN when the represented leaf area is zero.

Divide each section's latent heat flux `λE` (W m⁻²) by the sampled atmospheric
latent heat of vaporization `λ` (J kg⁻¹). `net_water_flux` is the signed plant
water exchange (kg s⁻¹); positive section fluxes sum into `transpiration`, and
negative fluxes into positive `condensation`. `transpiration_step` and
`transpiration_cumulative` are kg per timestep and since simulation start.
Monteith already accounts for exchanging leaf faces; do not multiply the mesh
area by two. This is an aggregation of the chosen leaf model, not a separate
plant water or carbon balance, and adds no stem/root fluxes.

The initial cumulative quantities permit an explicit nonzero baseline. The
scenario must bind their previous-timestep values; use [`plant_balance_spec`](@ref).
PlantBiophysics 0.18 does not declare producer contracts for A, Tₗ, or λE, so
their consumer ports remain uncontracted rather than claiming checked units.
"""
struct PlantBalance{T} <: AbstractPlant_BalanceModel
    initial_assimilation::T
    initial_transpiration::T
end

function PlantBalance(; initial_assimilation=0.0, initial_transpiration=0.0)
    assimilation, transpiration = promote(float(initial_assimilation), float(initial_transpiration))
    isfinite(assimilation) || throw(DomainError(assimilation, "Initial assimilation must be finite."))
    isfinite(transpiration) && transpiration >= zero(transpiration) ||
        throw(DomainError(transpiration, "Initial transpiration must be finite and non-negative."))
    return PlantBalance(assimilation, transpiration)
end

PlantSimEngine.inputs_(model::PlantBalance) = (
    leaf_areas=Required(AbstractVector{<:Real}),
    leaf_assimilation=Required(AbstractVector{<:Real}),
    leaf_temperatures=Required(AbstractVector{<:Real}),
    leaf_latent_heat=Required(AbstractVector{<:Real}),
    previous_assimilation=Default(model.initial_assimilation),
    previous_transpiration=Default(model.initial_transpiration),
)

function PlantSimEngine.outputs_(model::PlantBalance)
    z = zero(model.initial_assimilation)
    undefined_temperature = oftype(z, NaN)
    return (
        leaf_area=z,
        A_plant=z,
        assimilation_step=z,
        assimilation_cumulative=model.initial_assimilation,
        Tₗ_mean=undefined_temperature,
        Tₗ_min=undefined_temperature,
        Tₗ_max=undefined_temperature,
        net_water_flux=z,
        transpiration=z,
        condensation=z,
        transpiration_step=z,
        transpiration_cumulative=model.initial_transpiration,
    )
end

const PLANT_BALANCE_OUTPUTS = keys(PlantSimEngine.outputs_(PlantBalance()))
const PLANT_BALANCE_COLUMNS = NamedTuple{PLANT_BALANCE_OUTPUTS}(
    Tuple((:plant_balance, variable) for variable in PLANT_BALANCE_OUTPUTS),
)

PlantSimEngine.environment_inputs_(::PlantBalance) = (λ=0.0, duration=Hour(1))
PlantSimEngine.environment_outputs_(::PlantBalance) = NamedTuple()
PlantSimEngine.variable_contracts_(::PlantBalance) = (
    leaf_areas=LEAF_AREA_CONTRACT,
    previous_assimilation=ASSIMILATION_CUMULATIVE_CONTRACT,
    previous_transpiration=WATER_CUMULATIVE_CONTRACT,
    leaf_area=PLANT_AREA_CONTRACT,
    A_plant=ASSIMILATION_RATE_CONTRACT,
    assimilation_step=ASSIMILATION_STEP_CONTRACT,
    assimilation_cumulative=ASSIMILATION_CUMULATIVE_CONTRACT,
    Tₗ_mean=temperature_contract(:mean),
    Tₗ_min=temperature_contract(:minimum),
    Tₗ_max=temperature_contract(:maximum),
    net_water_flux=WATER_RATE_CONTRACT,
    transpiration=WATER_RATE_CONTRACT,
    condensation=WATER_RATE_CONTRACT,
    transpiration_step=WATER_STEP_CONTRACT,
    transpiration_cumulative=WATER_CUMULATIVE_CONTRACT,
)

PlantSimEngine.Authoring.model_metadata(::PlantBalance) = (
    hypothesis="Sum leaf surface fluxes over represented green leaf sections; area-weighted temperature and signed interval assimilation.",
    reference=nothing,
    maturity=:aggregation_of_leaf_model,
    validation=:structural_tests_only,
)
PlantSimEngine.Authoring.parameter_metadata(::PlantBalance) = (
    initial_assimilation=(
        description="Net assimilated CO₂ before the first simulated interval.",
        unit=:micromol_carbon_dioxide,
    ),
    initial_transpiration=(
        description="Transpired water before the first simulated interval.",
        unit=:kilogram_water, domain=(minimum=0,),
    ),
)

function PlantSimEngine.run!(::PlantBalance, status, environment, constants, context)
    n = length(status.leaf_areas)
    n == length(status.leaf_assimilation) == length(status.leaf_temperatures) == length(status.leaf_latent_heat) ||
        throw(DimensionMismatch("Plant balance inputs must select the same leaf sections in the same order."))
    λ = environment.λ
    isfinite(λ) && λ > zero(λ) || throw(DomainError(λ, "Latent heat of vaporization must be finite and positive (J kg⁻¹)."))
    duration = environment.duration
    seconds = duration isa Real ? duration : Dates.toms(duration) / 1000
    isfinite(seconds) && seconds > zero(seconds) || throw(DomainError(seconds, "Timestep duration must be finite and positive (s)."))

    area_total = zero(status.leaf_area)
    assimilation = zero(status.A_plant)
    weighted_temperature = zero(status.Tₗ_mean)
    minimum_temperature = oftype(weighted_temperature, Inf)
    maximum_temperature = oftype(weighted_temperature, -Inf)
    transpiration = zero(status.transpiration)
    condensation = zero(status.condensation)

    for i in eachindex(status.leaf_areas)
        area = status.leaf_areas[i]
        isfinite(area) && area >= zero(area) || throw(DomainError(area, "Leaf mesh area must be finite and non-negative (m²)."))
        iszero(area) && continue
        A = status.leaf_assimilation[i]
        temperature = status.leaf_temperatures[i]
        latent_heat = status.leaf_latent_heat[i]
        isfinite(A) && isfinite(temperature) && isfinite(latent_heat) ||
            throw(DomainError((A, temperature, latent_heat), "Simulated leaf fluxes and temperatures must be finite."))

        area_total += area
        assimilation += A * area
        weighted_temperature += temperature * area
        minimum_temperature = min(minimum_temperature, temperature)
        maximum_temperature = max(maximum_temperature, temperature)
        water_flux = latent_heat * area / λ
        transpiration += max(water_flux, zero(water_flux))
        condensation += max(-water_flux, zero(water_flux))
    end

    status.leaf_area = area_total
    status.A_plant = assimilation
    status.assimilation_step = assimilation * seconds
    status.assimilation_cumulative = status.previous_assimilation + status.assimilation_step
    undefined_temperature = oftype(weighted_temperature, NaN)
    status.Tₗ_mean = iszero(area_total) ? undefined_temperature : weighted_temperature / area_total
    status.Tₗ_min = iszero(area_total) ? undefined_temperature : minimum_temperature
    status.Tₗ_max = iszero(area_total) ? undefined_temperature : maximum_temperature
    status.net_water_flux = transpiration - condensation
    status.transpiration = transpiration
    status.condensation = condensation
    status.transpiration_step = transpiration * seconds
    status.transpiration_cumulative = status.previous_transpiration + status.transpiration_step
    return nothing
end

"""
    plant_balance_spec(model=PlantBalance(); leaf_kind=:active_leaf,
        light_application=:archimed_light, energy_application=:energy_balance,
        name=:plant_balance)

Apply a balance to every Plant, using green LeafSection descendants. Every
vector uses the same scale, kind, subtree, and HoldLast policy. The Monteith
application supplies the final accepted A, Tₗ, and λE; photosynthesis hard-call
trials are not used. Bind cumulative states with explicit PreviousTimeStep
inputs so rerunning a fresh simulation starts from its declared baseline.
"""
function plant_balance_spec(
    model=PlantBalance(); leaf_kind=:active_leaf,
    light_application=:archimed_light, energy_application=:energy_balance,
    name=:plant_balance,
)
    return ModelSpec(
        model; name=name, on=Many(scale=:Plant),
        inputs=(
            :leaf_areas => Many(scale=:LeafSection, kind=leaf_kind, within=Subtree(), application=light_application, var=:area, policy=HoldLast()),
            :leaf_assimilation => Many(scale=:LeafSection, kind=leaf_kind, within=Subtree(), application=energy_application, var=:A, policy=HoldLast()),
            :leaf_temperatures => Many(scale=:LeafSection, kind=leaf_kind, within=Subtree(), application=energy_application, var=:Tₗ, policy=HoldLast()),
            :leaf_latent_heat => Many(scale=:LeafSection, kind=leaf_kind, within=Subtree(), application=energy_application, var=:λE, policy=HoldLast()),
            PreviousTimeStep(:previous_assimilation) => One(within=Self(), application=name, var=:assimilation_cumulative),
            PreviousTimeStep(:previous_transpiration) => One(within=Self(), application=name, var=:transpiration_cumulative),
        ),
    )
end

end # module AgripvPlantBalance

"""Retain the plant balance streams with names distinct from leaf/light requests."""
function plant_output_requests()
    return PlantSimEngine.OutputRequest[
        PlantSimEngine.OutputRequest(
            PlantSimEngine.Many(scale=:Plant), variable;
            application=:plant_balance, name=Symbol(:plant_, variable),
        ) for variable in AgripvPlantBalance.PLANT_BALANCE_OUTPUTS
    ]
end

"""Materialize retained plant streams through the local wide-table collector."""
collect_plant_outputs(simulation, model; dates=nothing) =
    collect_selected_outputs(
        simulation, model;
        columns=AgripvPlantBalance.PLANT_BALANCE_COLUMNS,
        scale=:Plant,
        dates,
    )
