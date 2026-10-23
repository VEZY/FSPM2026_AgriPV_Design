# Historical filename: display a saved radiation snapshot, without simulating a static sky.
isdefined(@__MODULE__, :plot_saved_output) || include("daily_plotting.jl")

config_id = 0
day = Date(2025, 7, 2)
timestep = 13
f, ax, p = plot_saved_output(; config_id, day, timestep, table=:light,
    variable=:Ra_PAR_f, label="Absorbed PAR (W m⁻²)")
Label(f[0, :], "Saved absorbed PAR — Config $config_id — $day"; fontsize=20)

save(joinpath(_agripv_project_root(), "2_outputs", "static_config$(config_id)_n.png"),
    f; px_per_unit=3.0)
f
