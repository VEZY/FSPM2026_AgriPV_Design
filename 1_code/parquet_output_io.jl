using DuckDB, DBInterface, DataFrames, Dates, SHA, TOML

_agripv_sql_string(value) = "'" * replace(string(value), "'" => "''") * "'"
_agripv_sql_identifier(value) = "\"" * replace(string(value), "\"" => "\"\"") * "\""
_agripv_hash(path) = bytes2hex(open(SHA.sha256, path))

function _agripv_with_db(f; memory_limit="1GB")
    db = DuckDB.DB()
    con = DBInterface.connect(db)
    try
        DBInterface.execute(con, "SET memory_limit=$(_agripv_sql_string(memory_limit))")
        # DuckDB.jl reserves Julia threads for scans of registered Julia tables.
        DBInterface.execute(con, "SET threads=$(Threads.nthreads())")
        return f(con)
    finally
        DBInterface.close!(con)
        DBInterface.close!(db)
    end
end

_agripv_parquet_scan(paths) = "read_parquet([" * join(_agripv_sql_string.(paths), ',') * "], hive_partitioning=false)"

"""Write lossless Zstandard Parquet shards from bounded batches of one daily table."""
function _agripv_write_parquet(table, directory; day, compression_level=19, batch_rows=122880)
    1 <= compression_level <= 22 || throw(ArgumentError("Zstandard level must be 1–22."))
    batch_rows isa Integer && batch_rows > 0 || throw(ArgumentError("batch_rows must be a positive integer."))
    mkpath(directory)
    entries = Dict{String,Any}[]
    _agripv_with_db() do con
        for (part, start) in enumerate(isempty(table) ? [1] : 1:batch_rows:nrow(table))
            lastrow = min(start + batch_rows - 1, nrow(table))
            batch = DataFrame(table[start:lastrow, :])
            for name in propertynames(batch)
                if Base.nonmissingtype(eltype(batch[!, name])) <: Symbol
                    batch[!, name] = Union{Missing,String}[ismissing(x) ? missing : string(x) for x in batch[!, name]]
                elseif eltype(batch[!, name]) === Missing
                    batch[!, name] = Union{Missing,String}[missing for _ in batch[!, name]]
                end
            end
            file = "part-$(lpad(part-1, 6, '0')).parquet"
            path = joinpath(directory, file)
            DuckDB.register_table(con, batch, "output_batch")
            try
                DBInterface.execute(con, "COPY output_batch TO $(_agripv_sql_string(path)) (FORMAT PARQUET, COMPRESSION ZSTD, COMPRESSION_LEVEL $compression_level, ROW_GROUP_SIZE $batch_rows)")
            finally
                DuckDB.unregister_table(con, "output_batch")
            end
            # Check the lossless persisted batch, including NaN, missing and timestamps.
            reread = DataFrame(DBInterface.execute(con, "SELECT * FROM $(_agripv_parquet_scan([path]))"))
            isequal(batch, reread) || throw(ArgumentError("Parquet round-trip differs: $path"))
            push!(entries, Dict("file" => file, "day" => string(day), "rows" => nrow(batch),
                "bytes" => filesize(path), "sha256" => _agripv_hash(path)))
        end
    end
    return entries
end

_agripv_parquet_info(files; compression_level=19) = Dict("storage" => "parquet",
    "available" => true, "compression" => "zstd", "compression_level" => compression_level,
    "rows" => sum(x["rows"] for x in files; init=0), "files" => files)

function _agripv_saved_files(root, info; day=nothing, verify_hash=true)
    get(info, "available", true) || throw(ArgumentError("Requested output table is marked unavailable."))
    isnothing(day) && !get(info, "complete", true) &&
        throw(ArgumentError("This table is still being regenerated; select a completed day or wait for the full cycle."))
    entries = get(info, "files", nothing)
    isnothing(entries) && throw(ArgumentError("Expected a Parquet file manifest."))
    paths = String[]
    for entry in entries
        !isnothing(day) && get(entry, "day", "") != string(day) && continue
        path = abspath(joinpath(root, entry["file"]))
        relative = relpath(path, abspath(root))
        (relative == ".." || startswith(relative, "../")) && throw(ArgumentError("Output path escapes its run directory."))
        isfile(path) || throw(ArgumentError("Missing output shard: $path"))
        verify_hash && _agripv_hash(path) != entry["sha256"] && throw(ArgumentError("Output checksum differs: $path"))
        push!(paths, path)
    end
    isempty(paths) && throw(ArgumentError("No output shards for the selected date."))
    return paths
end

function _agripv_read_parquet(root, info; day=nothing, timestep=nothing, variables=nothing, verify_hash=true)
    paths = _agripv_saved_files(root, info; day, verify_hash)
    return _agripv_with_db() do con
        scan = _agripv_parquet_scan(paths)
        columns = propertynames(DataFrame(DBInterface.execute(con, "SELECT * FROM $scan LIMIT 0")))
        if !isnothing(timestep) && :timestep ∉ columns
            scan = "(SELECT *, dense_rank() OVER (PARTITION BY CAST(datetime AS DATE) ORDER BY datetime) AS timestep FROM $scan)"
            columns = [columns; :timestep]
        end
        selected = if isnothing(variables)
            "*"
        else
            requested = variables isa Symbol ? [variables] : collect(variables)
            isempty(setdiff(requested, columns)) || throw(ArgumentError("Unknown output columns: $(setdiff(requested, columns))"))
            identities = intersect([:node_id, :plant_id, :plant_instance_id, :timestep, :datetime, :object_id, :scale, :kind, :day, :config_id], columns)
            join(_agripv_sql_identifier.(unique([identities; requested])), ',')
        end
        predicates = String[]
        !isnothing(day) && push!(predicates, "CAST(datetime AS DATE) = DATE $(_agripv_sql_string(day))")
        !isnothing(timestep) && push!(predicates, "timestep = $(Int(timestep))")
        where_sql = isempty(predicates) ? "" : " WHERE " * join(predicates, " AND ")
        table = DataFrame(DBInterface.execute(con, "SELECT $selected FROM $scan$where_sql"))
        if isnothing(day) && isnothing(timestep)
            nrow(table) == info["rows"] || throw(ArgumentError("Output row count differs from metadata."))
        end
        return table
    end
end

"""Query saved tables with DuckDB; only query results are transferred to Julia."""
function with_saved_outputs(f; config_id, tables=(:plants,),
    input_dir=joinpath(@__DIR__, "..", "2_outputs", "simulations", "yearly"), day=nothing, verify_hash=true)
    metadata = TOML.parsefile(joinpath(input_dir, "scene_config_$(config_id).toml"))
    roles = tables isa Symbol ? (tables,) : tables
    return _agripv_with_db() do con
        for role in roles
            role in (:plants, :leaves, :light, :forcing) || throw(ArgumentError("Unknown table $role."))
            info = role == :forcing ? get(metadata, "forcing", nothing) : get(metadata["tables"], string(role), nothing)
            isnothing(info) && throw(ArgumentError("Run did not retain $role."))
            paths = _agripv_saved_files(input_dir, info; day, verify_hash)
            DBInterface.execute(con, "CREATE VIEW $(_agripv_sql_identifier(role)) AS SELECT * FROM $(_agripv_parquet_scan(paths))")
        end
        return f(con, metadata)
    end
end

"""Process saved Parquet in bounded row batches with optional column selection."""
function foreach_saved_output_batch(f; config_id, table=:leaves, columns=nothing,
    input_dir=joinpath(@__DIR__, "..", "2_outputs", "simulations", "yearly"),
    day=nothing, batch_rows=122880, verify_hash=true)
    batch_rows > 0 || throw(ArgumentError("batch_rows must be positive."))
    metadata = TOML.parsefile(joinpath(input_dir, "scene_config_$(config_id).toml"))
    info = table == :forcing ? metadata["forcing"] : get(metadata["tables"], string(table), nothing)
    isnothing(info) && throw(ArgumentError("Run did not retain $table."))
    paths = _agripv_saved_files(input_dir, info; day, verify_hash)
    selected = isnothing(columns) ? "*" : join(_agripv_sql_identifier.(columns), ',')
    count = 0
    _agripv_with_db() do con
        for path in paths
            scan = _agripv_parquet_scan([path])
            offset = 0
            while true
                batch = DataFrame(DBInterface.execute(con, "SELECT $selected FROM $scan LIMIT $batch_rows OFFSET $offset"))
                isempty(batch) && break
                f(batch)
                count += nrow(batch)
                offset += nrow(batch)
            end
        end
    end
    isnothing(day) && count != info["rows"] && throw(ArgumentError("Output row count differs from metadata."))
    return count
end

# Publish data and sidecar together; roll back both if either move fails.
function _agripv_publish_dataset(staging, output_dir, dataset, metadata_file)
    targets = [joinpath(output_dir, dataset), joinpath(output_dir, metadata_file)]
    backups = targets .* ".previous"
    any(ispath, backups) && throw(ArgumentError("A previous publication backup needs inspection."))
    old = ispath.(targets)
    published = falses(2)
    try
        for i in 1:2
            old[i] && mv(targets[i], backups[i])
        end
        for i in 1:2
            mv(joinpath(staging, i == 1 ? dataset : metadata_file), targets[i])
            published[i] = true
        end
    catch
        for i in 1:2
            published[i] && rm(targets[i]; recursive=true)
            ispath(backups[i]) && mv(backups[i], targets[i])
        end
        rethrow()
    end
    for backup in backups
        ispath(backup) && rm(backup; recursive=true)
    end
    return targets
end
