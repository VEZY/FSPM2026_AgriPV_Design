library(SticsRPacks)
library(dplyr)

# Give the path to the JavaSTICS installation (adapt to your own path):
javastics <- "/Users/rvezy/Downloads/JavaSTICS-10.5.0-STICS-10.5.0"

# Define the workspace and the output path for the simulations, the USMs to simulate and the variables to extract:
workspace <- file.path(javastics, "example")
output_path <- normalizePath("0_simulations/stics")
usms <- c("maize", "wheat", "sorghum", "proto_rice")
vars <- c(
  "lai_n",
  "hauteur",
  "somupvtsem",
  "laimax",
  "laisen_n",
  "raint",
  "trg_n",
  "ilevs",
  "iamfs",
  "ilaxs",
  "densite"
)

# Generate the files for the simulations:
gen_usms_xml2txt(
  javastics = javastics,
  workspace = workspace,
  out_dir = output_path,
  usm = usms,
)

# Make the simulations:
sim_options <- stics_wrapper_options(
  javastics = javastics,
  workspace = output_path,
  parallel = TRUE
)
results <- stics_wrapper(
  sim_options,
  situation = usms,
  var = vars
)

outputs <- select(CroPlotR::bind_rows(results$sim_list), -Plant)
write.csv(outputs, "0_simulations/stics/output_stics.csv", row.names = FALSE)

# We also need to copy the tec and plant files for ArchiCrop:
xml_files <- get_files_list(
  workspace = workspace,
  file_type = c("fplt", "ftec"),
  usm = usms,
  javastics = javastics
)

mapply(
  function(x, usm) {
    out_dir <- file.path(output_path, usm)
    file.copy(x$paths, out_dir, overwrite = TRUE)
  },
  xml_files,
  names(xml_files)
)

interrow <- c(
  "maize" = 0.6,
  "wheat" = 0.175,
  "sorghum" = 0.8,
  "proto_rice" = 0.1
)

density <- c(
  "maize" = 6,
  "wheat" = 70,
  "sorghum" = 5.4,
  "proto_rice" = 100
)

# Compute one-plant domain from interrow (x) and density (plants m-2).
# Area per plant = 1 / density, and along-row spacing (y) = area / interrow.
domain_per_plant <- dplyr::tibble(
  situation = names(interrow),
  interrow_m = as.numeric(interrow),
  density_plant_m2 = as.numeric(density)
) %>%
  dplyr::mutate(
    area_per_plant_m2 = 1 / density_plant_m2,
    intra_row_m = area_per_plant_m2 / interrow_m,
    xmin = -interrow_m / 2,
    xmax = interrow_m / 2,
    ymin = -intra_row_m / 2,
    ymax = intra_row_m / 2
  )

write.csv(
  domain_per_plant,
  "0_simulations/stics/domain_per_plant.csv",
  row.names = FALSE
)
