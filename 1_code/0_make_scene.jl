module MakeScene

using Agrivoltaics
using ArchimedLight
using Colors
using GeometryBasics
using MultiScaleTreeGraph
using PlantGeom

function make_simple_plant()
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

    plant = Node(NodeMTG(:/, :Plant, 1, 1))

    first_phy = emit_phytomer!(
        plant;
        internode=(link=:/, index=1, length=0.20, width=0.022),
        leaf=(index=1, offset=0.15, length=0.22, width=0.05, thickness=0.02, y_insertion_angle=52.0),
    )

    emit_phytomer!(
        first_phy.internode;
        internode=(index=2, length=0.18, width=0.020),
        leaf=(index=2, offset=0.14, length=0.24, width=0.055, thickness=0.02, phyllotaxy=180.0, y_insertion_angle=54.0),
    )

    rebuild_geometry!(plant, prototypes)
    return plant
end

function define_plant_design(panel_y_distance=10.0, plant_density=60.0, interrow=0.20, n_rows=1)
    intrarow = 1.0 / (plant_density * interrow)
    plants_per_row = max(1, floor(Int, panel_y_distance / intrarow) - 1)
    n_plants = plants_per_row * n_rows
    return intrarow, plants_per_row, n_plants
end

function add_crop!(
    scene_builder,
    plant_mtg;
    group,
    intrarow,
    plants_per_row,
    interrow,
    n_plants,
    random_rotation=5.0,
    start_id=2,
    x0=0.0,
    y0=0.0,
    z=0.0,
)
    for i in 1:n_plants
        col = (i - 1) % plants_per_row
        row = (i - 1) ÷ plants_per_row
        at = (x0 + (row + 0.5) * interrow, y0 + (col + 0.5) * intrarow, z)

        add_plant!(
            scene_builder,
            plant_mtg;
            group=group,
            id=start_id + i - 1,
            at=at,
            rotate=(z=randn() * random_rotation,),
            deg=true,
        )
    end

    return scene_builder
end

function make_scene(;
    plant_density=60.0,
    interrow=0.20,
    n_rows=2,
    panel_dimensions=(n_rows * interrow, 4.2),
    panel_y_distance=10.0,
    panel_inclination=25.0,
    panel_height=4.0,
    type="wheat",
)
    @assert type in ["wheat", "example_plant"] "Invalid plant type. Options are: 'wheat' or 'example_plant'."

    intrarow, plants_per_row, n_plants = define_plant_design(panel_y_distance, plant_density, interrow, n_rows)
    domain = (0.0, 0.0, interrow * n_rows, panel_y_distance)

    panel = Agrivoltaics.Fixed(
        panel_dimensions=panel_dimensions,
        inclination=panel_inclination,
        panel_height=panel_height,
    ) |> structure

    plant =
        if type == "wheat"
            read_opf("0_simulations/archicrop/wheat/plant_1995-06-24.opf", mtg_type=NodeMTG)
        else
            make_simple_plant()
        end

    return PlantGeom.make_scene(domain=domain) do s
        add_object!(s, panel; group="panel", type="Panel", id=1)
        add_crop!(
            s,
            plant;
            group=type,
            intrarow=intrarow,
            plants_per_row=plants_per_row,
            interrow=interrow,
            n_plants=n_plants,
        )
        add_ground!(s; nx=60, ny=60, group="pavement", type="Cobblestone")
    end
end

function models(type="wheat")
    @assert type in ["wheat", "example_plant"] "Invalid plant type. Options are: 'wheat' or 'example_plant'."

    plant_models =
        if type == "wheat"
            (
                "Stem" => translucent(par=0.15, nir=0.90),
                "Leaf" => translucent(par=0.15, nir=0.90),
            )
        else
            (
                "Internode" => translucent(par=0.15, nir=0.90),
                "Leaf" => translucent(par=0.15, nir=0.90),
            )
        end

    return models_for(
        "pavement" => ("Cobblestone" => translucent(par=0.12, nir=0.60),),
        "panel" => ("Panel" => translucent(par=0.0, nir=0.0),),
        type => plant_models,
    )
end

end # module
