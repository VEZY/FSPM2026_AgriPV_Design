include("0_configs.jl")

function wheat_models()
    models_for(
        "wheat" => (
            "Stem" => translucent(par=0.15, nir=0.90),
            "Leaf" => translucent(par=0.15, nir=0.90),
        ),
        "panel" => (
            "Panel" => translucent(par=0.0, nir=0.0),
        ),
        "pavement" => (
            "Cobblestone" => translucent(par=0.12, nir=0.60),
        ),
    )
end

function wheat_scene(;
    plant_density=60.0,
    n_rows=5,
    c = get_config(0)
)
    interrow = c.panel_x_distance / n_rows
    intrarow = 1.0 / (plant_density * interrow)
    print("Calculated from the plant_density and n_rows:\n\tInterrow: $interrow m\n\tIntrarow: $intrarow m\n-> If they are too different, ensure their consitency by playing with ``n_rows`` and ``panel_width``.")
    plants_per_row = max(1, floor(Int, c.panel_y_distance / intrarow) - 1)
    wheat_plant = read_opf("0_simulations/archicrop/wheat/static/plant_1995-06-24.opf", mtg_type=NodeMTG)
    panel = Agrivoltaics.Fixed(
        panel_dimensions=(c.panel_width, c.panel_length),
        inclination=c.panel_inclination,
        panel_height=c.panel_height,
    ) |> structure

    scene = PlantGeom.make_scene(domain=(0.0, 0.0, c.panel_x_distance, c.panel_y_distance)) do s
        add_object!(s, panel; group="panel", type="Panel", id=1)

        for i in 1:(plants_per_row*n_rows)
            row = (i - 1) ÷ plants_per_row
            col = (i - 1) % plants_per_row
            println("Plant n°$(i) in row $(row) column $(col)")
            add_plant!(
                s,
                wheat_plant;
                group="wheat",
                id=i + 1,
                at=((row + 0.5) * interrow, (col + 0.5) * intrarow, 0.0),
                rotate=(z=randn() * 5.0,),
                deg=true,
            )
        end

        add_ground!(s; nx=ground_res, ny=ground_res, group="pavement", type="Cobblestone")
    end

    return scene
end