using CSV, DataFrames, Dates, CodecZlib

const AGRIPV_LIGHT_EXPORT_COLUMNS = [
    :datetime, :node_id, :plant_id, :plant_instance_id,
    :scale, :kind, :Ra_PAR_f, :area,
]

_agripv_compact_light(table) = DataFrames.select(table, AGRIPV_LIGHT_EXPORT_COLUMNS; copycols=false)

"""Open plain or gzip light results without expanding the file on disk."""
function _agripv_open_light(f, path)
    open(path, "r") do raw
        if endswith(path, ".gz")
            io = GzipDecompressorStream(raw)
            try
                return f(io)
            finally
                close(io)
            end
        end
        return f(raw)
    end
end

function _agripv_restore_light_timestep!(table, day)
    :timestep in propertynames(table) && return table
    :datetime in propertynames(table) || throw(ArgumentError("Light results require datetime."))
    stamps = table.datetime
    all(x -> !ismissing(x) && Date(x) == Date(day), stamps) ||
        throw(ArgumentError("Light timestamps differ from the saved scene date."))
    lookup = Dict(stamp => step for (step, stamp) in enumerate(sort!(unique(stamps))))
    table.timestep = [lookup[stamp] for stamp in stamps]
    return table
end

isdefined(@__MODULE__, :foreach_saved_output_batch) || include("parquet_output_io.jl")
