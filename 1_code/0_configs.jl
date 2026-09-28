using CSV, DataFrames

struct ConfigPV
    panel_length::Float64
    panel_width::Float64
    panel_inclination::Float64
    panel_orientation::Float64  # 0° North, 90° East, 180° South, 270° West
    panel_height::Float64
    panel_x_distance::Float64
    panel_y_distance::Float64
    panel_tracking::Bool
end

function ConfigPV(;
    panel_length=4.2,
    panel_width=1.0,
    panel_inclination=25.0,
    panel_orientation=180.0,
    panel_height=4.0,
    panel_x_distance=panel_width,
    panel_y_distance=10.0,
    panel_tracking=false
)
    return ConfigPV(panel_length, panel_width, panel_inclination, panel_orientation, panel_height, panel_x_distance, panel_y_distance, panel_tracking)
end

function get_config(id::Int8)
    doe = CSV.read("0_simulations/doe.csv", DataFrame)
    filter!(x -> x.configID == id, doe)

    if isempty(doe)
        throw("ConfigPV($id) is not implemented yet")
    end

    # Process the panel_x_distance column if explicit non numerical parameters are given (e.g. panel_x_distance=panel_width)
    if isa(doe.panel_x_distance[1], String15)
        try
            if doe.panel_x_distance[1] == "panel_width"
                doe.panel_x_distance .= doe.panel_width[1]     # Get the Float value of panel_width
            else
                doe.panel_x_distance = parse.(Float64, doe.panel_x_distance)    # Convert column from String to Float
            end
        catch
            println("Accepted parameters for panel_x_distance are of Float64 type or 'panel_width'.")
        end
    end

    # Process the panel_y_distance column if explicit non numerical parameters are given (e.g. panel_y_distance=panel_length)
    if isa(doe.panel_y_distance[1], String15)
        try
            if doe.panel_y_distance[1] == "panel_length"
                doe.panel_y_distance .= doe.panel_length[1]     # Get the Float value of panel_length
            else
                doe.panel_y_distance = parse.(Float64, doe.panel_y_distance)    # Convert column from String to Float
            end
        catch
            println("Accepted parameters for panel_y_distance are of Float64 type or 'panel_length'.")
        end
    end

    return ConfigPV(
        panel_length=doe[1, :panel_length],
        panel_width=doe[1, :panel_width],
        panel_inclination=doe[1, :panel_inclination],
        panel_orientation=doe[1, :panel_orientation],
        panel_height=doe[1, :panel_height],
        panel_x_distance=doe[1, :panel_x_distance],
        panel_y_distance=doe[1, :panel_y_distance],
        panel_tracking=doe[1, :panel_tracking]
    )
end