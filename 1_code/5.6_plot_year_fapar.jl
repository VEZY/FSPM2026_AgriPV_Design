# Execute through Kaimon with mt=true (GLMakie). Each 14 GB light CSV is read
# once in 32 MiB batches; only the small hourly/daily summaries are retained.
include("year_fapar.jl")
include("year_fapar_plot.jl")

configIDs = 0:3
input_dir = joinpath(_fapar_project_root(), "2_outputs", "simulations", "yearly")
output_dir = joinpath(_fapar_project_root(), "2_outputs", "fapar")
mkpath(output_dir)

daily_tables = DataFrame[]
for configID in configIDs
    @info "Computing yearly faPAR" configID
    summary = summarize_year_fapar(; config_id=configID, input_dir)
    CSV.write(joinpath(output_dir, "fapar_hourly_config_$(configID).csv"), summary.hourly)
    CSV.write(joinpath(output_dir, "fapar_daily_config_$(configID).csv"), summary.daily)
    open(joinpath(output_dir, "fapar_info_config_$(configID).toml"), "w") do io
        TOML.print(io, Dict("config_id" => configID,
            "source_sha256" => summary.source_sha256, "source_rows" => summary.rows,
            "batch_bytes" => 32*1024^2,
            "incoming_source" => "current project climate and archimed_meteo sky preparation"))
    end
    push!(daily_tables, summary.daily)
end

fapar_daily = vcat(daily_tables...)
fapar_plot = plot_year_fapar(fapar_daily;
    output_path=joinpath(output_dir, "faPAR_over_time_plants_panels_ground.png"))
fapar_plot.figure
