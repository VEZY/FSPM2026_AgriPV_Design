using AlgebraOfGraphics, DataFrames, Statistics, CSV
using PlantMeteo, Dates, TableOperations, PlantMeteo.Tables

## COMPUTE WHEAT PHENOLOGICAL STAGES
## ASSOCIATE EACH STAGE WITH A SPECIFIC QUANTITY OF aPAR
## SETTING UP THE INITIAL SCENE
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

function init_scene(;
    plant_density=60.0,
    plant_interrow=0.20,
    n_rows=2,
    panel_length=4.2,
    panel_inclination=25.0,
    panel_height=4.0,
    panel_y_distance=10.0,
)
    plant_intrarow = 1.0 / (plant_density * plant_interrow)
    plants_per_row = max(1, floor(Int, panel_y_distance / plant_intrarow) - 1)
    panel_width = plant_interrow * n_rows
    wheat_plant = read_opf("0_simulations/archicrop/wheat/plant_stage_0.opf", mtg_type=NodeMTG)
    panel = Agrivoltaics.Fixed(
        panel_dimensions=(panel_width, panel_length),
        inclination=panel_inclination,
        panel_height=panel_height,
    ) |> structure

    scene = PlantGeom.make_scene(domain=(0.0, 0.0, panel_width, panel_y_distance)) do s
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
                at=((row + 0.5) * plant_interrow, (col + 0.5) * plant_intrarow, 0.0),
                rotate=(z=randn() * 5.0,),
                deg=true,
            )
        end

        add_ground!(s; nx=ground_res, ny=ground_res, group="pavement", type="Cobblestone")
    end

    return scene
end

@time scene = wheat_scene(
    plant_density=60.0,
    plant_interrow=0.20,
    n_rows=5,
    panel_length=4.2,
    panel_inclination=25.0,
    panel_height=4.0,
    panel_y_distance=10.0,
)

# write_ops("2_outputs/scene/simple_plant_scene.ops", scene.mtg)

plantviz(scene.mtg, figure=(size=(1080, 720),))

traverse!(scene.mtg) do node
    if symbol(node) == :Leaf
        node[:color] = node[:is_green] == true ? :green : :yellow
    end
    symbol(node) == :Stem && (node[:color] = :green)
    symbol(node) == :Panel && (node[:color] = :black)
end

# f, ax, p = plantviz(scene.mtg, figure=(size=(1080, 720),), color=:color)
# save("2_outputs/simple_plant_scene.png", f, update=false, px_per_unit=3.0)

models = wheat_models()



## SETTING UP THE METEOROLOGICAL DATA FOR THE SIMULATION
start_date = Date(2025, 2, 1)
end_date = Date(2025, 6, 30)
wheather_file = "0_simulations/meteo/meteo_data_2025_montpellier.csv"
metadata = (
    location="Montpellier",
    latitude=43.61,
    longitude=3.878,
    timezone="Europe/Paris")

meteo = read_weather(wheather_file, duration=x -> Hour(1));
meteo = Weather(meteo, metadata);
meteo_rows = TableOperations.filter(x -> start_date <= Date(Tables.getcolumn(x, :date)) <= end_date, meteo) |> (x -> TimeStepTable(x, metadata));

options = LightOptions(
    # turtle_sectors=46,
    turtle_sectors=16,
    pixel_size=0.01,
    toricity=true,
    scattering=true,
    cache_radiation=true,
    all_in_turtle=true,
    include_sky_fraction=true,
)

row = prepare_meteo(meteo_rows, options);




## COMPUTE RADIATIVE ENVIRONMENT FOR EACH DAY WITH aPAR
# --->  Compute radiation on current day scene
# |     Compute total aPAR for each plant
# |     Define new plant stage based on aPAR received
# LOOP
## COMPUTE THE GROWTH OF THE PLANT BASED ON THE aPAR RECEIVED
plant_stages_opf = Dict(
    0 => "0_simulations/archicrop/wheat/plant_stage_0.opf",
    1 => "0_simulations/archicrop/wheat/plant_stage_1.opf",
    2 => "0_simulations/archicrop/wheat/plant_stage_2.opf",
    3 => "0_simulations/archicrop/wheat/plant_stage_3.opf",
    4 => "0_simulations/archicrop/wheat/plant_stage_4.opf",
)
plant_stages_structure = Dict(
    0 => read_opf(plant_stages_opf[0], mtg_type=NodeMTG),
    1 => read_opf(plant_stages_opf[1], mtg_type=NodeMTG),
    2 => read_opf(plant_stages_opf[2], mtg_type=NodeMTG),
    3 => read_opf(plant_stages_opf[3], mtg_type=NodeMTG),
    4 => read_opf(plant_stages_opf[4], mtg_type=NodeMTG),
)

function update_wheat_growth(;
    scene,
    attached_aPAR_per_day,
)
    for node in scene.mtg
        if symbol(node) == :Plant
            plant_id = node[:id]
            aPAR = attached_aPAR_per_day[plant_id]
            println("Plant n°$(plant_id) received $(aPAR) MJ/m² of aPAR")
            if aPAR < 1.0
                new_stage = 0
            elseif aPAR < 2.0
                new_stage = 1
            elseif aPAR < 3.0
                new_stage = 2
            elseif aPAR < 4.0
                new_stage = 3
            else
                new_stage = 4
            end

            if node[:stage] != new_stage
                println("Plant n°$(plant_id) changes stage from $(node[:stage]) to $(new_stage)")
                node[:stage] = new_stage
                # Update the plant structure based on the new stage (e.g., read a different OPF file)
                new_plant_opf = "0_simulations/archicrop/wheat/plant_stage_$(new_stage).opf"
                new_plant_structure = read_opf(new_plant_opf, mtg_type=NodeMTG)
                # Replace the old plant structure with the new one in the scene
                replace_plant!(scene, plant_id, new_plant_structure)
            end
        end
    end
    return scene    # Useful ??
end

for day in start_date:end_date  # Each day in the simulation period
    println("Simulating day: $(day)")
    # Compute radiation on current day scene
    radiation_results = compute_radiation(scene, row, day; options=options)
    # Compute total aPAR for each plant
    attached_aPAR_per_day = compute_aPAR_per_plant(scene, radiation_results)
    # Update plant growth based on aPAR received
    scene = update_wheat_growth(scene=scene, attached_aPAR_per_day=attached_aPAR_per_day)
end





## DEPRECATED
function wheat_scene(;
    plant_density=60.0,
    plant_interrow=0.20,
    n_rows=2,
    panel_length=4.2,
    panel_inclination=25.0,
    panel_height=4.0,
    panel_y_distance=10.0,
)
    plant_intrarow = 1.0 / (plant_density * plant_interrow)
    plants_per_row = max(1, floor(Int, panel_y_distance / plant_intrarow) - 1)
    panel_width = plant_interrow * n_rows
    wheat_plant = read_opf("0_simulations/archicrop/wheat/static/plant_1995-06-24.opf", mtg_type=NodeMTG)
    panel = Agrivoltaics.Fixed(
        panel_dimensions=(panel_width, panel_length),
        inclination=panel_inclination,
        panel_height=panel_height,
    ) |> structure

    scene = PlantGeom.make_scene(domain=(0.0, 0.0, panel_width, panel_y_distance)) do s
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
                at=((row + 0.5) * plant_interrow, (col + 0.5) * plant_intrarow, 0.0),
                rotate=(z=randn() * 5.0,),
                deg=true,
            )
        end

        add_ground!(s; nx=ground_res, ny=ground_res, group="pavement", type="Cobblestone")
    end

    return scene
end