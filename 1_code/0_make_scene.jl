module MakeScene
using ArchimedLight, PlantGeom, MultiScaleTreeGraph, GeometryBasics, Agrivoltaics, Colors
using OrderedCollections: OrderedDict

function make_simple_plant()
    # Defining the reference meshes for the plant components (stem and leaf) and their prototypes:
    stem_ref = RefMesh(
        "stem",
        GeometryBasics.mesh(
            GeometryBasics.Cylinder(
                Point(0.0, 0.0, 0.0),
                Point(1.0, 0.0, 0.0),
                0.5,
            ),
        ),
        RGB(0.48, 0.36, 0.25),
    )

    leaf_ref = lamina_refmesh(
        "leaf";
        length=1.0,
        max_width=1.0,
        n_long=36,
        n_half=7,
        material=RGB(0.19, 0.61, 0.29),
    )

    prototypes = Dict(
        :Internode => RefMeshPrototype(stem_ref, true),
        :Leaf => PointMapPrototype(
            leaf_ref;
            defaults=(base_angle_deg=42.0, bend=0.30, tip_drop=0.08),
            intrinsic_shape=params -> LaminaMidribMap(
                base_angle_deg=params.base_angle_deg,
                bend=params.bend,
                tip_drop=params.tip_drop,
            ),
            warn=false,
        ),
    )

    # Defining the plant:
    small_plant = Node(NodeMTG(:/, :Plant, 1, 1))

    first_phy = emit_phytomer!(
        small_plant;
        internode=(link=:/, index=1, length=0.20, width=0.022),
        leaf=(index=1, offset=0.15, length=0.22, width=0.05, thickness=0.02, y_insertion_angle=52.0),
    )

    emit_phytomer!(
        first_phy.internode;
        internode=(index=2, length=0.18, width=0.020),
        leaf=(index=2, offset=0.14, length=0.24, width=0.055, thickness=0.02, phyllotaxy=180.0, y_insertion_angle=54.0),
    )

    rebuild_geometry!(small_plant, prototypes)

    return small_plant
end


"""
    define_plant_design(panel_y_distance=10.0, plant_density=60.0, interrow=0.20, n_rows=1)

Given the scene length (distance along the y-axis), plant density (plants per m^2) and interrow spacing (m), calculate the intrarow spacing, 
number of plants per row, number of rows and total number of plants that can fit in the scene.
"""
function define_plant_design(panel_y_distance=10.0, plant_density=60.0, interrow=0.20, n_rows=1)
    # From density and interrow, derive in-row spacing.
    intrarow = 1.0 / (plant_density * interrow)
    # With half-spacing margins on both sides, fit only full spacing intervals in the scene width.
    plants_per_row = max(1, floor(Int, panel_y_distance / intrarow) - 1)
    n_plants = plants_per_row * n_rows

    return intrarow, plants_per_row, n_plants
end

"""
    place_plants_in_scene!(; scene_mtg, plant_mtg, intrarow, plants_per_row, interrow, n_plants, random_rotation=5.0)

Place the plants in the scene MTG according to the specified design parameters (intrarow spacing, number of plants per row, 
interrow spacing) and add a random rotation to each plant for visual interest.
"""
function place_plants_in_scene!(; scene_mtg, plant_mtg, intrarow, plants_per_row, interrow, n_plants, random_rotation=5.0)

    @assert !isnothing(plant_mtg[:functional_group]) "The plant MTG must have a :functional_group attribute to be placed in the scene."
    @assert !isnothing(scene_mtg.scene_dimensions) "The scene MTG must have :scene_dimensions attribute defined to place the plants in the scene."

    # Place the plants in rows:
    pmin, _ = scene_mtg.scene_dimensions
    xmin, ymin, zmin = pmin[1], pmin[2], pmin[3]

    for i in 1:n_plants
        col = (i - 1) % plants_per_row
        row = (i - 1) ÷ plants_per_row
        # Center first plants at half-spacing so scene boundaries sit midway between plants.
        x = xmin + (row + 0.5) * interrow
        y = ymin + (col + 0.5) * intrarow

        rot_plant = randn() * random_rotation  # Random rotation for visual interest

        plant = deepcopy(plant_mtg)
        place_in_scene!(
            plant;
            scene=scene_mtg,
            scene_id=1,
            plant_id=i + 1,
            functional_group=plant_mtg[:functional_group],
            pos=(x, y, zmin),
            rotation=rot_plant,
            rebind_scene=false,
        )
    end

    MultiScaleTreeGraph.columnarize!(scene_mtg)
end

"""
    make_scene(; scene_dimensions, plant_density, interrow, panel_dimensions, panel_inclination, panel_height)

Create the scene MTG with the specified design parameters for the plant stand and the solar panel.
"""
function make_scene(; plant_density=60.0, interrow=0.20, n_rows=2, panel_dimensions=(n_rows * interrow, 4.2), panel_y_distance=10.0, panel_inclination=25.0, panel_height=4.00, type="wheat")


    # Define plant design:
    intrarow, plants_per_row, n_plants = define_plant_design(panel_y_distance, plant_density, interrow, n_rows)

    @assert typeof(type) <: AbstractString "Please specify only one plant type for the scene. Options are: 'wheat' or 'example_plant'."
    @assert type in ["wheat", "example_plant"] "Invalid plant type. Options are: 'wheat' or 'example_plant'."

    # Read the solar panel:
    # panel = read_opf("0_simulations/archimed/objects/panel.opf", mtg_type=NodeMTG)
    panel = Agrivoltaics.Fixed(panel_dimensions=panel_dimensions, inclination=panel_inclination, panel_height=panel_height) |> structure

    # Make the plant:
    if type == "wheat"
        small_plant = read_opf("0_simulations/archicrop/wheat/plant_1995-06-24.opf", mtg_type=NodeMTG)
    elseif type == "example_plant"
        small_plant = make_simple_plant()
    end
    small_plant[:functional_group] = type

    # Make the scene node:
    scene_mtg = Node(NodeMTG(:/, :Scene, 1, 1))

    # Set scene dimensions
    scene_mtg.scene_dimensions = (
        Point3(0.0, 0.0, 0.0),
        Point3(interrow * n_rows, panel_y_distance, 0.0)
    )

    # Place the solar panel in the scene:
    place_in_scene!(
        panel;
        scene=scene_mtg,
        scene_id=1,
        plant_id=1,
        functional_group="panel",
        pos=(0.0, 0.0, 0.0),
        rebind_scene=false,
        # scale=1.15,
        # rotation=-0.35,
        # inclination_angle=0.12,
    )

    place_plants_in_scene!(
        scene_mtg=scene_mtg,
        plant_mtg=small_plant,
        intrarow=intrarow,
        plants_per_row=plants_per_row,
        interrow=interrow,
        n_plants=n_plants,
        random_rotation=5.0,
    )

    # Make the Archimed Light scene and add the ground:
    scene = prepare_scene(scene_mtg)

    add_ground!(
        scene;
        nx=60,
        ny=60,
        # xy_bounds=(0.0, 0.0, 1.0, 10.0),
        group="pavement",
        type="Cobblestone",
    )
end

function models(type="wheat")
    @assert typeof(type) <: AbstractString "Please specify only one plant type for the models. Options are: 'wheat' or 'example_plant'."
    @assert type in ["wheat", "example_plant"] "Invalid plant type. Options are: 'wheat' or 'example_plant'."

    models = [
        GroupModel(
            "pavement";
            types=OrderedDict(
                "Cobblestone" => TypeModel(
                    interception=InterceptionModel(
                        model="Translucent",
                        transparency=0.0,
                        optical_properties=OpticalProperties(0.12, 0.60),
                    ),
                ),
            ),
        ),
        GroupModel(
            "panel";
            types=OrderedDict(
                "Panel" => TypeModel(
                    interception=InterceptionModel(
                        model="Translucent",
                        transparency=0.0,
                        optical_properties=OpticalProperties(0.0, 0.0),
                    ),
                ),
            ),
        ),
    ]

    if type == "wheat"
        push!(
            models,
            GroupModel(
                "wheat";
                types=OrderedDict(
                    "Stem" => TypeModel(
                        interception=InterceptionModel(
                            model="Translucent",
                            transparency=0.0,
                            optical_properties=OpticalProperties(0.15, 0.90),
                        ),
                    ),
                    "Leaf" => TypeModel(
                        interception=InterceptionModel(
                            model="Translucent",
                            transparency=0.0,
                            optical_properties=OpticalProperties(0.15, 0.90),
                        ),
                    ),
                ),
            )
        )
    elseif type == "example_plant"
        push!(
            models,
            GroupModel(
                "example_plant";
                types=OrderedDict(
                    "Internode" => TypeModel(
                        interception=InterceptionModel(
                            model="Translucent",
                            transparency=0.0,
                            optical_properties=OpticalProperties(0.15, 0.90),
                        ),
                    ),
                    "Leaf" => TypeModel(
                        interception=InterceptionModel(
                            model="Translucent",
                            transparency=0.0,
                            optical_properties=OpticalProperties(0.15, 0.90),
                        ),
                    ),
                ),
            )
        )
    end
    prepare_models(models)
end

end # module
