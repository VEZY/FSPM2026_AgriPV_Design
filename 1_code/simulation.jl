function day_simulation(; pvconfig, models, day, meteo, options)
    n_rows = 2
    scene = agripv_scene(
        plant_density=60.0,
        n_rows=n_rows,
        c=pvconfig,
        day=day
    )
    # f, ax, p = plantviz(scene_ref.mtg, figure=(size=(1080, 720),))
    sim = LightSimulation(scene, models; options=options)
    series = run_light(sim, meteo)

    # Attach the results to the MTG for visualization:
    attach_light_series!(
        scene,
        series;
        fields=[:incident_par_flux, :absorbed_par_flux, :absorbed_par_energy, :absorbed_nir_flux, :absorbed_nir_energy, :sky_fraction, :area],
    )

    # Adapting variables for PlantBiophysics :
    MultiScaleTreeGraph.transform!(
        scene.mtg,
        [:Ra_PAR_f, :Ra_NIR_f] => ((x, y) -> x .+ y) => :Ra_SW_f,
        ignore_nothing=true
    )

    # Simulate energy balance and photosynthesis with PlantBiophysics::
    vars = Dict{Symbol,Any}(:Leaf => (:Tₗ, :A, :Gₛ))
    models =
        ModelMapping(
            "Leaf" => (
                Translucent(), # This model reads ArchimedLight outputs one time-step at a time
                Monteith(),
                Fvcb(),
                Medlyn(0.03, 12.0),
                Status(d=0.01) #! update this with the true value in the MTG
            ),
        )
    outs = PlantSimEngine.run!(scene.mtg, models, meteo, tracked_outputs=vars)
    # Writing the outputs back to the MTG for visualization:
    for ts_node in groupby(DataFrame(outs[:Leaf]), :node)
        node = ts_node.node[1]
        node.Tₗ = ts_node.Tₗ
        node.A = ts_node.A
        node.A_per_organ = ts_node.A .* node.area
        node.Gₛ = ts_node.Gₛ
    end

    # Compute the absorbed PAR and A by each plant over the day, by summing the absorbed PAR energy of all the leaves of each plant at each timestep:
    plant_df = let
        apar_plant = []
        assimilation_quantity_plant = [] # Assimilation in μmol per plant per timestep, i.e. A (μmol m⁻² s⁻¹) * leaf area (m²) * duration of the timestep (s)
        plan_index = []
        traverse!(scene.mtg) do node
            if symbol(node) == :Plant
                push!(apar_plant, [sum(leaf[timestep] for leaf in descendants(node, :Ra_PAR_q, symbol=:Leaf)) for timestep in 1:length(meteo)] * 1e-6) # Convert from J to MJ
                push!(assimilation_quantity_plant, [sum(leaf[timestep] for leaf in descendants(node, :A_per_organ, symbol=:Leaf)) * Dates.toms(r.duration) * 1e-3 for (timestep, r) in enumerate(meteo)])
                push!(plan_index, fill(node_id(node), length(meteo)))
            end
        end
        DataFrame(plant_id=vcat(plan_index...), date=repeat(meteo.date, outer=length(plan_index)), apar=vcat(apar_plant...), assimilation=vcat(assimilation_quantity_plant...))
    end

    return scene, sim, series, plant_df
end