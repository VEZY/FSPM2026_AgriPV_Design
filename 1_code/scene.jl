using FileIO, GeometryBasics, CoordinateTransformations, MultiScaleTreeGraph, PlantGeom
using ArchimedLight
using Dates, Glob, Agrivoltaics
using SHA

_agripv_file_sha256(path) = bytes2hex(open(SHA.sha256, path))

function _agripv_plant_paths(day, obj_path, mtg_path)
    if isnothing(obj_path)
        directory = normpath(joinpath(@__DIR__, "..", "2_outputs", "archicrop"))
        candidates = sort(glob("*$day.obj", directory))
        length(candidates) == 1 || throw(ArgumentError(
            "Expected one plant OBJ for $day; found $(length(candidates)). Specify obj_path explicitly.",
        ))
        obj_path = only(candidates)
    end
    isnothing(mtg_path) && (mtg_path = first(splitext(obj_path)) * ".mtg")
    isfile(obj_path) || throw(ArgumentError("Plant OBJ not found: $obj_path"))
    isfile(mtg_path) || throw(ArgumentError("Plant MTG not found: $mtg_path"))
    return abspath(obj_path), abspath(mtg_path)
end

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
            candidate_senescent_id = string(parse(Int, Id) + 10000000)
            if symbol(node) == :Stem
                mesh_id = haskey(meshes, Id) ? Id : candidate_senescent_id
                node[:geometry] = PlantGeom.Geometry(ref_mesh=RefMesh(mesh_id, meshes[mesh_id]))
                # A stem is a radiative object, not a photosynthetic leaf section.
                return
            end
            section_parent = node
            if haskey(meshes, Id)
                section_parent = MultiScaleTreeGraph.addchild!(
                    node,
                    NodeMTG("/", "LeafSection", 1, MultiScaleTreeGraph.scale(node)+1),
                    Dict(
                        :geometry => PlantGeom.Geometry(ref_mesh=RefMesh(Id, meshes[Id])),
                        :state=>"active",
                    )
                )
            end
            # A completely senescent leaf may have no corresponding active mesh.
            if haskey(meshes, candidate_senescent_id)
                link = section_parent === node ? "/" : "<"
                index = section_parent === node ? 1 : 2
                MultiScaleTreeGraph.addchild!(
                    section_parent, NodeMTG(link, "LeafSection", index, MultiScaleTreeGraph.scale(node)+1),
                    Dict(
                        :geometry => PlantGeom.Geometry(ref_mesh=RefMesh(candidate_senescent_id, meshes[candidate_senescent_id])),
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
    ground_res=60,
    obj_path=nothing,
    mtg_path=nothing,
    plant_rotations=nothing,
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
    obj_path, mtg_path = _agripv_plant_paths(day, obj_path, mtg_path)
    wheat_plant = read_plant(obj_path, mtg_path)
    nplants = plants_per_row * n_rows
    # Save actual radians, rather than a random seed, so reconstruction replays
    # the placements independently of the global RNG and its implementation.
    rotations = isnothing(plant_rotations) ?
        [deg2rad(randn() * 5.0) for _ in 1:nplants] : Float64.(plant_rotations)
    length(rotations) == nplants && all(isfinite, rotations) || throw(ArgumentError(
        "plant_rotations must contain $nplants finite angles in radians.",
    ))
    recipe = Dict{String,Any}(
        "day" => string(day),
        "config" => Dict(string(name) => getproperty(c, name) for name in propertynames(c)),
        "plant_density" => Float64(plant_density),
        "ground_res" => Int(ground_res),
        "plant_rotations_rad" => rotations,
        "obj_path" => obj_path, "mtg_path" => mtg_path,
        "obj_sha256" => _agripv_file_sha256(obj_path),
        "mtg_sha256" => _agripv_file_sha256(mtg_path),
    )
    panel = Agrivoltaics.Fixed(
        panel_dimensions=(c.panel_width, c.panel_length),
        inclination=c.panel_inclination,
        panel_height=c.panel_height,
    ) |> structure

    scene = PlantGeom.make_scene(domain=(0.0, 0.0, c.panel_x_distance, c.panel_y_distance)) do s
        add_object!(s, panel; group="panel", type="Panel", id=1)

        for i in 1:nplants
            row = (i - 1) ÷ plants_per_row
            col = (i - 1) % plants_per_row
            # println("Plant n°$(i) in row $(row) column $(col)")
            add_plant!(
                s,
                wheat_plant;
                group="wheat",
                id=i + 1,
                at=((row + 0.5) * interrow, (col + 0.5) * intrarow, 0.0),
                rotate=(z=rotations[i],),
                deg=false,
            )
        end

        add_ground!(s; nx=ground_res, ny=ground_res, group="pavement", type="Cobblestone")
    end

    scene.mtg[:agripv_scene_recipe] = recipe
    return scene
end
