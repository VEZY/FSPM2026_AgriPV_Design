using PlantSimEngine, PlantBiophysics, PlantMeteo, DataFrames, CSV, Dates, TableOperations
using ArchimedLight, PlantMeteo.Tables

include("meteo.jl")
include("scene.jl")
if !isdefined(@__MODULE__, :AgripvPlantBalance)
    include("plant_balance.jl")
end
using .AgripvPlantBalance
include("simulation_outputs.jl")

"""Build the scene and coupled models without running or materializing outputs."""
function prepare_day_simulation(; pvconfig, day, scene_kwargs=NamedTuple(), meteo=nothing)
    meteo = isnothing(meteo) ? get_meteo(day) : meteo
    isempty(meteo) && throw(ArgumentError("No meteorology for $day"))
    all(row -> Date(row.date) == day, meteo) || throw(ArgumentError(
        "Daily meteorology must contain only $day.",
    ))
    scene = agripv_scene(; c=pvconfig, day, scene_kwargs...)
    options = LightOptions(
        turtle_sectors=46,
        pixel_size=0.01,
        toricity=true,
        scattering=true,
        cache_radiation=true,
        all_in_turtle=true,
        include_sky_fraction=true,
        scene_rotation_deg=pvconfig.panel_orientation,
    )
    meteo = archimed_meteo(meteo, options)
    light_sim = LightSimulation(scene, agripv_models(); options)

    # Indexed kinds cover actual geometry without a scene-sized ID tuple.
    geometry_targets = Many(
        kind=(:active_leaf, :senescent_leaf, :radiative_geometry), within=SceneScope(),
    )
    light_application = ModelSpec(
        ArchimedLightModel(light_sim; output_schema=:coupling,
            par_energy_to_photon=PlantMeteo.Constants().J_to_umol);
        name=:archimed_light, on=One(scale=:Scene),
        outputs_to=(OutputTo(geometry_targets; coverage=:exact),),
    )
    active_sections = Many(scale=:LeafSection, kind=:active_leaf)
    photosynthesis = ModelSpec(
        Fvcb(VcMaxRef=120.0, JMaxRef=240.0, RdRef=1.2, TPURef=20.0);
        name=:photosynthesis, on=active_sections,
        inputs=(
            :aPPFD => One(within=Self(), application=:archimed_light,
                var=:aPPFD, policy=HoldLast()),
        ),
    )
    energy_balance = ModelSpec(
        Monteith(aₛᵥ=2); name=:energy_balance, on=active_sections,
        inputs=(
            :Ra_SW_f => One(within=Self(), application=:archimed_light,
                var=:Ra_SW_f, policy=HoldLast()),
            :sky_fraction => One(within=Self(), application=:archimed_light,
                var=:sky_fraction, policy=HoldLast()),
        ),
    )
    stomatal_conductance = ModelSpec(
        # Small positive intercept requested for this scenario. The
        # PlantBiophysics source fix handles zero/low-light singularities.
        # Retain the existing gs_min=0.001 mol CO₂ m⁻² s⁻¹ conductance floor.
        Medlyn(1e-6, 5.8); name=:stomatal_conductance, on=active_sections,
    )
    function node_kind(node)
        isnothing(node[:geometry]) && return nothing
        MultiScaleTreeGraph.symbol(node) == :LeafSection || return :radiative_geometry
        return node[:state] == "senescent" ? :senescent_leaf : :active_leaf
    end
    first_forcing = first(meteo)
    # Declare the shared hard-call trial slots explicitly. These match
    # Monteith's initialization, which overwrites them before every leaf solve.
    initial_status(node) = node_kind(node) == :active_leaf ? Status(
        d=0.01,
        Tₗ=first_forcing.T - 0.2,
        Cₛ=first_forcing.Cₐ,
        A=0.0,
        Dₗ=PlantMeteo.e_sat(first_forcing.T - 0.2) -
            PlantMeteo.e_sat(first_forcing.T) * first_forcing.Rh,
    ) : Status()

    # Parameter sources retained from the original setup: Camino et al. (2019),
    # Table 2; Townsend et al. (2018), Table III; Medlyn et al. (2002);
    # wheat USO study (2025), section 2.2; CLM5 documentation, Table 9.1.
    # d is the characteristic leaf dimension (m); replace with measurements.
    coupled = CompositeModel(
        scene.mtg; status=initial_status, kind=node_kind,
        applications=(light_application, energy_balance, photosynthesis,
            stomatal_conductance, plant_balance_spec()),
        environment=meteo,
    )
    return (; coupled, scene, meteo, light_sim)
end

"""
    day_simulation(; pvconfig, day, keep_leaves=true, keep_light=true, scene_kwargs=(), meteo=nothing)

Run hourly radiation on all geometry and physiology on active leaf sections.
Return wide `leaves`, `light` and `plants` DataFrames, plus the simulation,
scene and meteorology. Each table has one row per source MTG `node_id` and
`timestep`, with variables as columns. `plant_id` identifies the Plant ancestor.
Leaf rows combine physiology, radiation and surface-integrated section rates.
Keep `scene.mtg` to reassociate exported values with its LeafSection nodes.
Plant quantities are surface weighted and integrate
actual step durations. Set `keep_leaves=false, keep_light=false` for plant
summaries alone. No global long-table sort or automatic resampling is needed.
Supply `meteo` to reuse already-read forcing for this date; otherwise the
climate file is read by `get_meteo(day)`.
"""
function day_simulation(; pvconfig, day, keep_leaves=true, keep_light=true,
    scene_kwargs=NamedTuple(), meteo=nothing)
    setup = prepare_day_simulation(; pvconfig, day, scene_kwargs, meteo)
    requests = plant_output_requests()
    if keep_leaves
        append!(requests, leaf_output_requests())
    end
    if keep_light
        append!(requests, light_output_requests())
    end
    simulation = PlantSimEngine.run!(setup.coupled;
        steps=length(setup.meteo), outputs=requests)
    dates = [row.date for row in setup.meteo]
    plants = collect_plant_outputs(simulation, setup.coupled; dates)
    leaves = keep_leaves ? collect_leaf_outputs(simulation, setup.coupled; dates, meteo=setup.meteo) : DataFrame()
    light = keep_light ? collect_light_outputs(simulation, setup.coupled; dates) : DataFrame()
    return (; leaves, plants, light, simulation, scene=setup.scene, meteo=setup.meteo)
end

# map = (
#     Ri_PAR_0_f=(:incident_flux, :initial, :par),
#     Ri_NIR_0_f=(:incident_flux, :initial, :nir),
#     Ri_PAR_f=(:incident_flux, :total, :par),
#     Ri_NIR_f=(:incident_flux, :total, :nir),
#     Ri_PAR_0_q=(:incident_energy, :initial, :par),
#     Ri_NIR_0_q=(:incident_energy, :initial, :nir),
#     Ri_PAR_q=(:incident_energy, :total, :par),
#     Ri_NIR_q=(:incident_energy, :total, :nir),
#     Ra_PAR_0_f=(:absorbed_flux, :initial, :par),
#     Ra_NIR_0_f=(:absorbed_flux, :initial, :nir),
#     Ra_PAR_f=(:absorbed_flux, :total, :par),
#     Ra_NIR_f=(:absorbed_flux, :total, :nir),
#     Ra_PAR_0_q=(:absorbed_energy, :initial, :par),
#     Ra_NIR_0_q=(:absorbed_energy, :initial, :nir),
#     Ra_PAR_q=(:absorbed_energy, :total, :par),
#     Ra_NIR_q=(:absorbed_energy, :total, :nir),
# )

function read_component_values(; csv_path, timestep=1, variable=:Ri_PAR_f)
    component_values = CSV.read(csv_path, DataFrame)
    # Current tables and legacy ArchimedLight exports both use actual MTG IDs.
    step_column = :timestep in propertynames(component_values) ? :timestep : :step_number
    sdf = filter(step_column => ==(timestep), component_values)
    values_dict = Dict(Int(i) => Float64(v) for (i, v) in zip(sdf.node_id, sdf[!, variable])
        if !ismissing(i) && !ismissing(v) && isfinite(v))

    return values_dict
end

function read_aPAR_from_component_values(; csv_path)
    component_values = CSV.read(csv_path, DataFrame; delim=(';'))
    df = filter(:group => ==("wheat"), component_values)
    values_df = combine(groupby(df, [:step_number, :object_id]), :Ra_PAR_q => sum => :Ra_PAR_q_sum)

    return values_df
end
