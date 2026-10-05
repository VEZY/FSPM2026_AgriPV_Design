using FileIO, GeometryBasics, CoordinateTransformations, MultiScaleTreeGraph, PlantGeom
using ArchimedLight
using Dates, Glob, Agrivoltaics

function read_plant(obj_path::AbstractString, mtg_path::AbstractString)
    # obj_path = normpath("./mtg_obj/usm_1_2.5D_2018-10-09_1.obj")
    # mtg_path = joinpath(dirname(obj_path), first(split(basename(obj_path), ".")) * ".mtg")
    mesh_plant = load(obj_path)
    splitted_mesh = split_mesh(GeometryBasics.Mesh(mesh_plant))
    # mesh_plant[:object] #! use this to index by object id!!
    length(splitted_mesh) == 0 && return nothing
    # Map the meshes object ids from the .obj file to the splitted meshes, and scale from cm to m:
    scale = 0.01 ##check if need to update
    meshes = Dict{String,GeometryBasics.Mesh}()
    for (i, obj) in enumerate(mesh_plant[:object])
        # i=1; obj = mesh_plant[:object][i]
        mesh_ = splitted_mesh[i]
        c, f = coordinates(mesh_), faces(mesh_)
        meshes[split(obj, "_")[end]] = GeometryBasics.Mesh(scale * c, f)
    end

    mtg = read_mtg(mtg_path, NodeMTG)

    # Re-attach the geometry to the MTG using the Ids from the .obj files and the MTG attribute
    traverse!(mtg) do node
        Id = string(node[:Id])
        if Id != "nothing" && (haskey(meshes, Id) || haskey(meshes, string(parse(Int, Id) + 10000000)))
            if symbol(node) == :Stem
                node[:geometry] = PlantGeom.Geometry(ref_mesh=RefMesh(Id, meshes[Id]))
            end
            # Senescent meshes are defined with Id + 10000000, so we check if the senescent mesh exists and add it as a child node to the MTG.
            active_leaf = MultiScaleTreeGraph.addchild!(
                node,
                NodeMTG("/", "LeafSection", 1, MultiScaleTreeGraph.scale(node)+1),
                Dict(
                    :geometry => PlantGeom.Geometry(ref_mesh=RefMesh(Id, meshes[Id])),
                    :state=>"active",
                )
            )
            # node[:geometry] = PlantGeom.Geometry(
            #     ref_mesh=RefMesh(Id, meshes[Id]),
            # )
            candidate_senescent_id = string(parse(Int, Id) + 10000000)
            if haskey(meshes, candidate_senescent_id)
                MultiScaleTreeGraph.addchild!(
                    active_leaf, NodeMTG("<", "LeafSection", 2, MultiScaleTreeGraph.scale(node)+1),
                    Dict(
                        :geometry => PlantGeom.Geometry(ref_mesh=RefMesh(Id, meshes[candidate_senescent_id])),
                        :state=>"senescent",
                    )
                )
            end
        end
    end

    return mtg
end

function agripv_models()
    models_for(
        "wheat" => (
            "Stem" => translucent(par=0.15, nir=0.90),
            "LeafSection" => translucent(par=0.15, nir=0.90),
        ),
        "panel" => (
            "Panel" => translucent(par=0.0, nir=0.0),
        ),
        "pavement" => (
            "Cobblestone" => translucent(par=0.12, nir=0.60),
        ),
    )
end

function agripv_scene(;
    plant_density=60.0,
    c=get_pvconfig(0),
    day=Date(2025, 7, 2),
    ground_res=60
)
    # The size of the scene (panel_x_distance, panel_y_distance) should
    # be a multiple of the interrow in x, and of the intrarow in y.
    # nb_of_plants = (c.panel_x_distance * c.panel_y_distance) * plant_density
    # x_ratio = c.panel_x_distance / c.panel_y_distance
    # n_rows = 
    n_rows = round(Int, c.panel_x_distance * sqrt(plant_density))
    interrow = c.panel_x_distance / n_rows
    intrarow = 1.0 / (plant_density * interrow)

    # BELOW is useful in case of user-defined interrow/intrarow
    if abs(interrow-intrarow) > 0.05
        throw("Abort for interrow-intrarow mismatch.\n\t-> Interrow of $interrow m and intrarow of $intrarow m are too different to be realistic.")
    end

    plants_per_row = max(1, floor(Int, c.panel_y_distance / intrarow) - 1)
    obj_path = glob("2_outputs/archicrop/*$day.obj")[1]
    mtg_path = glob("2_outputs/archicrop/*$day.mtg")[1]
    wheat_plant = read_plant(obj_path, mtg_path)
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
            # println("Plant n°$(i) in row $(row) column $(col)")
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