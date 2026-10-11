using CSV, DataFrames
using GLMakie
using GeometryBasics: Polygon

df = CSV.read("2_outputs/simulations/yearly/config_summary.csv", DataFrame)
config_order = [0, 1, 3, 2]
radial_min, radial_max = 1.0, 1.75
all(config_id -> config_id in df.config_id, config_order) ||
    throw(ArgumentError("The summary must contain Config 0, Config 1, Config 2, and Config 3."))
length(unique(df.config_id)) == nrow(df) ||
    throw(ArgumentError("The summary must contain only one row per configuration."))

rows_by_config = Dict(row.config_id => row for row in eachrow(df))
assimilation = [rows_by_config[id].total_assimilation_mean_per_plant / 1e5 for id in config_order]
transpiration = [rows_by_config[id].total_transpiration_mean_per_plant for id in config_order]
angles = deg2rad.([135, 45, -45, -135])
config_labels = ["Config $id" for id in config_order]

function plot_radar_grid!(axis)
    ring_angles = range(0, 2pi; length=361)
    text!(
        axis,
        -0.06,
        -0.06;
        text=string(radial_min),
        align=(:right, :top),
        fontsize=10,
        color=:gray35,
    )
    for tick_value in (1.25, 1.5, radial_max)
        radius = 2 * (tick_value - radial_min) / (radial_max - radial_min)
        lines!(
            axis,
            radius .* cos.(ring_angles),
            radius .* sin.(ring_angles);
            color=:gray75,
            linewidth=1,
        )
        text!(
            axis,
            -radius / sqrt(2) - 0.025,
            -radius / sqrt(2);
            text=string(tick_value),
            align=(:right, :center),
            fontsize=10,
            color=:gray35,
        )
    end

    for angle in angles
        lines!(
            axis,
            [0, 2 * cos(angle)],
            [0, 2 * sin(angle)];
            color=:gray65,
            linewidth=1,
        )
    end
end

function radar_points(values)
    radii = 2 .* (values .- radial_min) ./ (radial_max - radial_min)
    x = radii .* cos.(angles)
    y = radii .* sin.(angles)
    return [Point2f(x[i], y[i]) for i in eachindex(x)]
end

function plot_radar_fill!(axis, values, color)
    poly!(axis, Polygon(radar_points(values)); color=(color, 0.25), strokewidth=0)
end

function plot_radar_series!(axis, values, color, label)
    points = radar_points(values)
    lines!(
        axis,
        vcat(points, points[1:1]);
        color,
        linewidth=3,
        label,
    )
    scatter!(axis, points; color, markersize=12)
end

function plot_config_labels!(axis)
    for (angle, label) in zip(angles, config_labels)
        text!(
            axis,
            2.25 * cos(angle),
            2.25 * sin(angle);
            text=label,
            align=(:center, :center),
            fontsize=13,
        )
    end
end

fig = Figure(size=(900, 700))
radar_axis = Axis(
    fig[1, 1],
    aspect=DataAspect(),
    limits=(-2.3, 2.3, -2.3, 2.3),
)
hidedecorations!(radar_axis)
hidespines!(radar_axis)

plot_radar_grid!(radar_axis)
all(value -> radial_min <= value <= radial_max, assimilation) ||
    throw(ArgumentError("Assimilation values must be within the radar scale [$radial_min, $radial_max]."))
all(value -> radial_min <= value <= radial_max, transpiration) ||
    throw(ArgumentError("Transpiration values must be within the radar scale [$radial_min, $radial_max]."))
plot_radar_fill!(radar_axis, assimilation, :darkorange)
plot_radar_fill!(radar_axis, transpiration, :steelblue)
plot_radar_series!(
    radar_axis,
    assimilation,
    :darkorange,
    "Mean total assimilation per plant [×10⁻¹ mol CO₂]",
)
plot_radar_series!(
    radar_axis,
    transpiration,
    :steelblue,
    "Mean total transpiration per plant [kg H₂O]",
)
plot_config_labels!(radar_axis)
Legend(
    fig[2, 1],
    radar_axis;
    orientation=:horizontal,
    framevisible=false,
    tellwidth=false,
    tellheight=false,
    halign=:center,
    valign=:center,
)
rowsize!(fig.layout, 2, Fixed(45))

save("2_outputs/plots/yearly_skill_summary.png", fig)
fig
