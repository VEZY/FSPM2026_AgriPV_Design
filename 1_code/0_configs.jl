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
    panel_width,
    panel_inclination=25.0,
    panel_orientation=180.0,
    panel_height=4.0,
    panel_x_distance=panel_width,
    panel_y_distance=10.0,
    panel_tracking=false
)
    return ConfigPV(panel_length, panel_width, panel_inclination, panel_orientation, panel_height, panel_x_distance, panel_y_distance, panel_tracking)
end

function get_config(id::Int8, panel_width::Float64)
    if id == 0
        return ConfigPV(  # GCR 40% ; tilted, East-West
            panel_length=4.2,
            panel_width=panel_width,
            panel_inclination=25.0,
            panel_orientation=180.0,
            panel_height=4.0,
            panel_x_distance=panel_width,
            panel_y_distance=10.0,
            panel_tracking=false
        )
    elseif id == 1
        return ConfigPV(  # GCR 40% ; flat, East-West
            panel_length=3.0,
            panel_width=panel_width,
            panel_inclination=0.0,
            panel_orientation=180.0,
            panel_height=4.0,
            panel_x_distance=panel_width,
            panel_y_distance=10.0,
            panel_tracking=false
        )
    elseif id == 2
        return ConfigPV(  # GCR 40% ; flat, North-South
            panel_length=3.0,
            panel_width=panel_width,
            panel_inclination=0.0,
            panel_orientation=90.0,
            panel_height=4.0,
            panel_x_distance=10.0,
            panel_y_distance=panel_width,
            panel_tracking=false
        )
    # elseif id == 3
    #     return ConfigPV(

    #     )
    # elseif id == 4
    #     return ConfigPV(

    #     )
    # elseif id == 5
    #     return ConfigPV(

    #     )
    # elseif id == 6
    #     return ConfigPV(

    #     )
    else
        throw("ConfigPV($id) is not implemented yet")
    end
end