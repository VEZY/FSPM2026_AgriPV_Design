# Daily light and physiology simulation

First, instantiate the project:

```julia
using Pkg
Pkg.instantiate()
```

!!! note PlantBiophysics version

    This project uses the `fix-root-in-fvcb` branch of
    [PlantBiophysics](https://github.com/VEZY/PlantBiophysics.jl/tree/fix-root-in-fvcb),
    which includes the numerical fix inside the original `Fvcb` and its regression
    tests. Project.toml records the Git source; the tracked Manifest.toml pins its
    source tree. PlantSimEngine is unchanged. In a Kaimon session started for this project, a clean checkout can install the dependencies with:

To make a daily simulation, run the script `4.2_run_day_simulation.jl`. It
writes three CSV tables: `out_config_*` for green leaf sections,
`light_config_*` for all geometric objects, and `plants_config_*` for plant
summaries. These are wide tables: one row per object and publication timestep.
It also writes `scene_config_ID_DATE.toml` alongside them for scene reconstruction.
All three include `node_id`, the exact node ID in the returned scene MTG,
and `plant_id`, its nearest Plant ancestor's node ID. A Plant row uses its
own node ID as `plant_id`. `plant_instance_id` is the Plant ancestor's `:plantID`
placement attribute, set by `add_plant!(...; id=...)`, and identifies the same
planting position when scenes are rebuilt with a fixed layout. Ground and
panels have no plant IDs. `plant_instance_id` is also `missing` for an MTG
whose Plant ancestor has no placement ID; all MTG identity columns are
`missing` for generic Object scenarios. `object_id` retains
the PlantSimEngine identity, which can differ from `node_id`. Neither refers
to an object's position in an array or to the original OBJ `:Id` attribute,
which can repeat between plants. `datetime` comes from the forcing.

| Returned table | Rows | Variables as columns |
| --- | --- | --- |
| `result.leaves` | Active LeafSection × timestep | A, Tₗ, Gₛ, λE, all retained light variables, section assimilation and transpiration |
| `result.light` | Geometric node × timestep | Incident/absorbed PAR and NIR, absorbed shortwave, aPPFD, area, sky fraction |
| `result.plants` | Plant node × timestep | Surface-integrated assimilation and water exchange, weighted/extreme temperatures, cumulative quantities |

For interactive use:

```julia
include("1_code/simulation.jl")
include("1_code/pvconfig.jl")
result = day_simulation(pvconfig=get_pvconfig(0), day=Date(2025, 7, 2));
result.plants
```

For example, `filter(:timestep => ==(13), result.leaves)` selects the noon
snapshot for the supplied 2025-07-02 forcing. The ID belongs to
`result.scene.mtg`, including its added LeafSection nodes. Keep that MTG (or a
copy preserving its node IDs), or rebuild it from the saved scene recipe as below.
A raw crop template is a different tree.

## Simulate the growing period

Run `4.3_run_year_simulation.jl` through Kaimon from the project root. It uses
the same hourly ArchimedLight and PlantBiophysics coupling as the daily script
for configurations 0–3. The plant OBJ filenames in `2_outputs/archicrop/`
define the dates: each must end in `YYYY-MM-DD.obj` and have a matching `.mtg`.
The driver selects `wheat_*.obj`; adjust `plant_dir` and `plant_pattern` for
another crop series. Dates are sorted chronologically; gaps are not filled.
Missing MTGs, duplicate plant dates or missing climate dates raise an error.
The current input series covers 121 days, 2025-03-04 through 2025-07-02.

Both drivers explicitly pass `stics_density = 268.0` plants m⁻² through
`scene_kwargs=(plant_density=stics_density,)`. Keep this value aligned in
`4.2_run_day_simulation.jl` and `4.3_run_year_simulation.jl` when changing the
STICS density. The scene builder rounds the planting layout to fit the domain;
the requested density and actual rotations are stored in each scene recipe.

The climate file is read once for all configurations. For each date the runner
builds a fresh scene with that day's growing plant maquette and the supplied
PV configuration, prepares that day's forcing, and runs the complete daily
coupling. Plant placements and rotations remain fixed across the period within
each configuration. The plant geometry changes with the maquettes.

The yearly runner calls `day_simulation` directly: both paths therefore share
the light options in `prepare_day_simulation` (46 turtle sectors, 0.01 m pixels,
toricity, scattering, radiation caching, direct light distributed into turtle
sectors, sky fractions and the PV configuration's scene rotation), the optical
models, ground grid and PlantBiophysics parameters. Independently started daily
runs draw new plant rotations; use the yearly recipe's `plant_rotations_rad`
as `scene_kwargs.plant_rotations` to replay exactly the same scene. The tests
compare standalone daily results against both dates of a reduced yearly run
with these rotations and the same weather, density and geometry sources.

Existing output files retain their original scene settings. Rerun simulations
after changing the density, then recompute yearly faPAR from the new outputs.
Compare the saved recipes' `plant_density` values before comparing daily and
yearly results generated at different times.

Results are appended daily, keeping only a single day's simulation and tables
in memory. In `2_outputs/simulations/yearly/`, each configuration produces:

- `out_config_ID.csv`: active leaf sections across all simulated days;
- `plants_config_ID.csv`: plant summaries across all simulated days;
- `light_config_ID.csv`: radiation on all geometric objects across all days;
- `scene_config_ID.toml`: dates, per-day scene recipes and fingerprints, and CSV hashes.

CSV columns match the daily tables, with added `day` and `config_id`. Each
`datetime` is the actual forcing timestamp. `timestep` starts at 1 each day;
`node_id`, `plant_id` and `object_id` refer to that day's scene and must be used
together with `day`. Changing plant topology can change these IDs across days.
Use `(config_id, plant_instance_id)` to follow a planted individual across
days, and `(config_id, day, node_id)` to locate an exact daily scene node.
`plant_instance_id` stays fixed because it comes from the plant's placement ID,
independently of its changing organ count. This requires a fixed planting layout
and plant enumeration within each configuration; it does not identify the same
plant across different configurations. The TOML records
`plant_instance_identity_scope = "configuration"`, alongside the existing
`identity_scope = "day"` for scene node identities.
The plant `assimilation_cumulative` and `transpiration_cumulative` columns are
**within-day** cumuls, reset at each new daily simulation. Use the step amounts
grouped by `(config_id, plant_instance_id)` to compute period totals. This workflow
uses supplied growth geometry; it does not feed assimilation back into growth.

Exports are built in a temporary directory and replace the configuration's
output files only after all selected dates succeed. A simulation failure leaves
previous completed outputs intact. The period TOML contains one recipe per
date; `load_day_outputs` remains the loader for daily exports.

For a short run or plant summaries alone:

```julia
include("1_code/year_simulation.jl")
summary = year_simulation(pvconfig=get_pvconfig(0), config_id=0,
    plant_pattern="wheat_*.obj", days=[Date(2025, 3, 4), Date(2025, 7, 2)],
    keep_leaves=false, keep_light=false,
    output_dir="2_outputs/simulations/period_check")
summary.paths
summary.rows
```

Omit `days` to simulate every available maquette date. Pass `scene_kwargs` as
in `day_simulation` for a smaller scene during verification. A supplied `meteo`
table lets several configurations reuse already-read forcing; the runner
checks coverage and selects each day's rows before calling `day_simulation`.

## Plot yearly faPAR without loading the light CSVs

Run `5.6_plot_year_fapar.jl` through Kaimon with `mt=true` for GLMakie. It
processes configurations 0–3 and writes
`2_outputs/fapar/faPAR_over_time_plants_panels_ground.png`, with one panel per
configuration and daily curves for plants, solar panels, ground and their sum.
The horizontal reference at one helps inspect the radiation balance.

`year_fapar.jl` reads each light CSV sequentially in **32 MiB input batches**,
parses only eight necessary columns, and retains totals per timestamp. It
never reads or memory maps the entire light file. Parsed columns and Julia's
runtime require additional memory; memory use is independent of the full CSV
size. Source SHA256 and row count are checked against the simulation sidecar
during the same pass, without a second scan.

For category `g`, absorbed energy is
`sum(Ra_PAR_f * area * duration_s)` over its geometric objects and timesteps.
Plants include all objects with `plant_id`, including stems and senescent leaf
sections. The other categories are `Panel` and `Cobblestone`. There is no extra
factor of two for leaf faces. Incoming energy is sky `Ri_PAR_f * duration_s *
horizontal_scene_area`, where the area comes from the saved PV configuration.
The light table's object-level `Ri_PAR_f` includes intercepted/scattered light
and is not the denominator.

Daily fractions divide summed absorbed energy by summed incoming energy;
they are not an unweighted mean of hourly ratios. Nighttime hourly fractions
are `missing`. No fraction is clipped or renormalized. The total can be below
one because some scattered PAR escapes upward, with raster/scattering
tolerances also contributing. `nonabsorbed_fraction = 1 - fapar_total` records
that difference; it is not an independently measured reflected-energy budget.

Small `fapar_hourly_config_ID.csv` and `fapar_daily_config_ID.csv` tables retain
energies in joules and fractions, and `fapar_info_config_ID.toml` records the
source hash. Sky forcing is reconstructed with the same `archimed_meteo` path
as the simulation, assuming the climate file and preparation code have not
changed. To use an archived run's exact prepared forcing, supply its table
explicitly:

```julia
include("1_code/year_fapar.jl")
summary = summarize_year_fapar(config_id=0, forcing=original_prepared_meteo)
```

The forcing must have `date`, `duration` and sky `Ri_PAR_f` columns and cover
exactly the light run's timestamps. To redraw the figure without rescanning
the large files:

```julia
using CSV, DataFrames, Dates
include("1_code/year_fapar_plot.jl") # mt=true
daily = vcat([CSV.read("2_outputs/fapar/fapar_daily_config_$(id).csv", DataFrame;
    types=Dict(:day => Date))
    for id in 0:3]...)
plot_year_fapar(daily;
    output_path="2_outputs/fapar/faPAR_over_time_plants_panels_ground.png")
```

On 2026-10-08 all four production light files were processed and their source
hashes verified: 298,143,168 rows, 121 dates per configuration, 11,616 hourly
and 484 daily summaries. Daily total faPAR ranged from 0.9212 to 0.9468.
The 51 focused tests passed through Kaimon with Julia 1.13.1, CSV 1.1.0 and
ArchimedLight 0.2.0. They check area/duration integration, energy weighting,
plant categories, missing dark ratios, batch equivalence and invalid inputs.

## Reload CSVs and rebuild their scene

The daily loop calls `write_day_outputs(result; config_id=configID)`. This keeps
the original three CSV names and adds a small TOML sidecar. It records the
resolved configuration values, date, plant density, ground resolution, exact
plant OBJ/MTG files and **actual random plant rotations**. Saving the rotations
matters: calling `agripv_scene` again with only the config/date otherwise gives
different geometry, even though the node IDs are the same.

Later, in a new Kaimon session for this project:

```julia
include("1_code/saved_simulation.jl")
saved = load_day_outputs(config_id=0, day=Date(2025, 7, 2))

attach_outputs!(saved.scene.mtg, saved.leaves;
    timestep=13, variables=(:A, :Tₗ, :transpiration_flux))
attach_outputs!(saved.scene.mtg, saved.light;
    timestep=13, variables=(:Ri_PAR_f,))
```

This reads the CSVs, rebuilds only the scene and reassociates values by `node_id`;
it does not rerun radiation, physiology or meteorology. The saved configuration
is used even if the DOE CSV has since changed. Source-file hashes, node metadata,
world-space scene geometry and CSV hashes must match. Keep the TOML and CSVs
together; source paths are relative to this project, so the project can move.
The original OBJ/MTG inputs must remain available and unchanged.
Earlier exports with a TOML recipe remain readable when their tables have no
`plant_instance_id` column. New exports include that column, and the loader
checks it against the rebuilt scene's Plant placement IDs.

For plotting, execute with `mt=true`:

```julia
include("1_code/5.2_plot_day_simulation.jl")
f, ax, p = plot_output(saved.scene.mtg, saved.leaves;
    variable=:A, timestep=13)

# Or reload, rebuild, attach and plot in one call:
f, ax, p = plot_saved_output(config_id=0, day=Date(2025, 7, 2),
    table=:light, variable=:Ri_PAR_f, timestep=13)
```

`load_day_outputs(...; tables=(:leaves,))` reads only the leaf CSV.
Both helpers accept `output_dir` for another results directory. Tables not
retained by the run are empty. CSVs from earlier exports without the TOML
recipe cannot recover their original random rotations; re-export an updated
run with `write_day_outputs` to use the exact reconstruction workflow.

## Reassociate outputs and plot with PlantViz

`attach_outputs!` copies scalar values for one timestep onto their source MTG
nodes. It builds the node lookup once, checks the whole snapshot before
writing, and leaves absent/nonfinite values as `nothing` for PlantViz's missing
color. By default it clears only the selected variables on other nodes, so
an earlier snapshot cannot leave stale colors. Other MTG attributes are kept.

```julia
attach_outputs!(result.scene.mtg, result.leaves;
    timestep=13, variables=(:A, :Tₗ, :transpiration_flux))
attach_outputs!(result.scene.mtg, result.light;
    timestep=13, variables=(:Ri_PAR_f, :aPPFD))
```

The plotting helper activates GLMakie:

```julia
include("1_code/5.2_plot_day_simulation.jl")
f, ax, p = plot_output(result.scene.mtg, result.leaves;
    variable=:A, timestep=13, label="Net assimilation (μmol CO₂ m⁻² s⁻¹)")
f, ax, p = plot_output(result.scene.mtg, result.light;
    variable=:Ri_PAR_f, timestep=13, label="Incident PAR (W m⁻²)")
```

`plot_output` attaches the requested variable and computes a finite, nonconstant
color range, including when radiation is zero everywhere at night. Nodes
without this variable use `color_missing` (default gray). For one plant, filter
the leaf table by `plant_id` before plotting that Plant subtree. Plant summaries
can also be attached with `attach_outputs!`; they belong to Plant nodes, which
have no geometry themselves, so they do not automatically color descendant
leaves as leaf fluxes.

To keep leaf and plant values together on the MTG, use `clear=false` when
attaching the plant table: both tables have columns such as `transpiration`.
The default `clear=true` clears each selected variable on all nodes and is
appropriate for replacing a plot snapshot.

```julia
attach_outputs!(result.scene.mtg, result.leaves; timestep=13)
attach_outputs!(result.scene.mtg, result.plants; timestep=13, clear=false)
```

CSV files keep the same column layout. `read_component_values` accepts current
`timestep` or legacy `step_number` tables, with `variable` and `timestep`
keywords, and returns a node-ID dictionary for ArchimedLight's `lightplot`.

Use `keep_leaves=false, keep_light=false` to retain and materialize plant
summaries alone. `prepare_day_simulation(...)` returns the scene, light
simulation, meteorology and coupled model without executing it. `scene_kwargs`
can pass scene construction settings, for example `(plant_density=1.0,
ground_res=4)` for a small coupling check.

## Retention and collection

The daily driver uses explicit `OutputRequest`s. Radiation uses ArchimedLight's
`:coupling` schema: the PAR/NIR incident and absorbed fluxes, absorbed shortwave
flux, aPPFD, area and sky fraction. Physiology retains the final Monteith
publication of A, Tₗ, Gₛ and λE. The leaf table includes the light columns
directly from those same publications; it does not join a long table. The plant application runs
after its leaf inputs are published.

`collect_selected_outputs` reads the public `PlantSimEngine.outputs(simulation)`
streams, queries objects through `model_objects`, and preallocates columns. It
avoids the legacy global sort of all `(object, variable, timestep)` rows.
Publications missing at a step remain `missing`; the collector does not add
held values or interpolate. The daily driver has synchronous hourly outputs.
These helpers target static scenes and integer publication steps. They do not
export removed objects from a dynamic lifecycle or resample another clock.

The radiation publisher covers every node with geometry, including stems,
senescent sections, panels and ground. Physiological applications and plant
summaries select active leaf sections. The scene reader no longer duplicates a
stem's mesh into a LeafSection.

## Plant quantities

The area is ArchimedLight's represented mesh surface (m²), used once. Monteith's
`aₛᵥ=2` already accounts for the exchanging leaf faces.

Leaf A remains a surface flux in μmol CO₂ m⁻² s⁻¹, and Tₗ is in °C. The combined
leaf table additionally computes these quantities using the actual forcing
latent heat of vaporization λ and duration:

| Leaf column | Meaning and unit |
| --- | --- |
| `A_section` | A × area, μmol CO₂ s⁻¹ per LeafSection |
| `assimilation_step` | A_section × duration, μmol CO₂ per LeafSection |
| `net_water_flux` | λE × area / λ, signed kg water s⁻¹ per LeafSection |
| `transpiration_flux` | max(λE / λ, 0), kg water m⁻² s⁻¹ |
| `transpiration` | Positive net_water_flux, kg water s⁻¹ per LeafSection |
| `condensation` | Magnitude of negative net_water_flux, kg water s⁻¹ per LeafSection |
| `transpiration_step` | Transpiration × duration, kg water per LeafSection |

These section rates and step amounts sum to their corresponding plant columns.
Radiation columns ending in `_f` are W m⁻²; `aPPFD` is μmol photons m⁻² s⁻¹.

| Column | Meaning and unit |
| --- | --- |
| `leaf_area` | Sum of represented active leaf areas, m² |
| `A_plant` | Σ(A × area), net μmol CO₂ s⁻¹ |
| `assimilation_step` | Net assimilation integrated over actual forcing duration, μmol CO₂ |
| `assimilation_cumulative` | Sum of step assimilation from the simulation baseline, μmol CO₂ |
| `Tₗ_mean` | Leaf temperature weighted by area, °C |
| `Tₗ_min`, `Tₗ_max` | Extrema over positive-area active sections, °C |
| `net_water_flux` | Σ(λE × area / λ), signed kg water s⁻¹ |
| `transpiration` | Sum of positive section water fluxes, kg s⁻¹ |
| `condensation` | Magnitude of negative section water fluxes, kg s⁻¹ |
| `transpiration_step` | Transpiration integrated over actual duration, kg |
| `transpiration_cumulative` | Sum of step transpiration from the simulation baseline, kg |

Temperatures are NaN for plants without represented active leaf area. Negative
net assimilation is preserved. Water exchange uses atmospheric λ in J kg⁻¹;
`Gₛ` is a conductance and is not a transpiration rate. Cumulative quantities
use explicit previous-timestep bindings. This aggregates the chosen leaf model;
it does not add plant respiration, root/stem exchange, or hydraulic feedbacks.

The original photosynthetic parameters and Medlyn slope remain assumptions of
this scenario. Medlyn uses the requested `g0=1e-6` mol CO₂ m⁻² s⁻¹ and retains
its existing `gs_min=0.001` conductance floor. The PlantBiophysics branch solves
net assimilation together with the actual conductance, including its floor.
At zero light, `A = -Rd`; below the compensation point, a positive gross
photosynthetic contribution is retained even when net `A` remains negative.
Intercellular CO₂ follows `Cᵢ = Cₛ - A/Gₛ`, so `Cᵢ > Cₛ` during CO₂ release.
The analytical coupling also supports Tuzet and directly prescribed conductance
with ConstantGs. This corrects the numerical coupling; it does not calibrate
nighttime respiration or stomatal parameters against measurements.
Structural checks do not establish predictive accuracy.

## Validation and performance

On 2026-10-07 the growth-period runner completed all 121 actual maquette dates
on a reduced configuration-0 scene (`plant_density=1.0`, `ground_res=2`), with
24 hourly steps per day and plant summaries retained: 2,904 coupled steps and
11,616 plant rows. CSV date coverage, hashes and fixed rotations were checked.
A separate two-day run using the first and last actual maquettes retained all
three tables and wrote 4,608 leaf, 13,968 light and 192 plant rows. These are
integration checks on small scenes; the four complete production scenes over
the full period were not run. Artifacts are in
`2_outputs/validation/2026-10-07-growth-period/` and
`2_outputs/validation/2026-10-07-growth-period-all-days/`.

The period regression tests generate their own dated OBJ/MTG pairs and use
the tracked climate file, so they do not require ignored ArchiCrop outputs.
They cover changing active/senescent geometry, two full days, chronological
exports, daily cumulative resets, missing inputs, selective retention and
preserving previous exports when a later day's simulation fails.
The complete project regression suite passed 1,170 checks through Kaimon.

On 2026-10-07, the complete PlantBiophysics package suite passed 2,086 checks
through Kaimon's dedicated test runner with Julia 1.13.1, including 1,495 FvCB
regressions. The daily evaluation fixture declares its time-column schema
explicitly for CSV 0.10 and 1.x. This project's 1,038 checks also passed after
restarting Kaimon with the Git dependency at commit
[`c9be0d9`](https://github.com/VEZY/PlantBiophysics.jl/commit/c9be0d9e9adac097d37638d0dab29dcfa69e6795).
The loaded FvCB method was verified against that dependency's source tree,
`21ee627bb05f647cf8272ce4af17f869a7b9c38f`, which is recorded in Manifest.toml.

Execute `include("1_code/tests/runtests.jl")` through Kaimon. Tests compare the
wide collector with PlantSimEngine's retained publications, including native
IDs, Float32 values, missing publications, dates and explicit retention. Plant
checks cover uneven surfaces, separate plants, senescent exclusion, condensation,
variable durations, empty plants, cumulative state and continuation. MTG checks
use engine IDs different from node IDs and repeated OBJ IDs, and verify merged
leaf columns, ancestor identity, snapshot attachment and validation before writing.

A fresh full-scene comparison on 2026-10-07 used the same configuration 0,
2025-07-02 forcing, 24 hourly steps, geometry, and retained output requests.
After compilation, the previous guard-only dependency took 93.03 s; the signed
coupling correction took 92.46 s. Total allocated bytes were 14.92 GB in both
runs. These are individual local measurements, so the small timing difference
is not evidence of a speedup. A separate process-kernel benchmark over five
light levels measured a median of 89.7 ns/call before and 101.8 ns/call after
(one million calls, five repetitions), with no additional per-call allocations.
The analytical correction introduced no material slowdown in this full scene.
All 342,912 leaf rows had finite `A`, `Tₗ`, `Gₛ`, and `λE`. The exported tables
contained 1,115,160 light rows and 7,296 plant rows. At the final nighttime
step, all 14,288 active sections had finite `Cᵢ` above `Cₛ` while respiring;
the maximum absolute diffusion residual was 2.22e-16 μmol CO₂ m⁻² s⁻¹.
Leaf, light, and plant collection took 3.32 s, 4.93 s, and 0.19 s respectively.

For a bounded timing check on the current scene, execute through Kaimon:

```julia
include("1_code/simulation.jl")
include("1_code/pvconfig.jl")
setup = prepare_day_simulation(pvconfig=get_pvconfig(0), day=Date(2025, 7, 2))
requests = [plant_output_requests(); leaf_output_requests(); light_output_requests()]
@time sim = run!(setup.coupled; steps=1, outputs=requests)
dates = [row.date for row in setup.meteo]
@time leaves = collect_leaf_outputs(sim, setup.coupled; dates, meteo=setup.meteo)
@time light = collect_light_outputs(sim, setup.coupled; dates)
@time plants = collect_plant_outputs(sim, setup.coupled; dates)
```

Warm compilation before comparing timings. Total allocated bytes reported by
Julia's `@time` are not peak resident memory.

Measured on 2026-10-06 with Julia 1.13.1, PlantSimEngine 0.15.0,
PlantBiophysics 0.18.0, ArchimedLight 0.2.0 and PlantMeteo 0.9.1 in this project:

| Collection on the original scene, one hour | Time | Total allocated | Rows |
| --- | ---: | ---: | ---: |
| Original `outputs=:all`, long DataFrame | 22.89 s | 24.33 GB | 1,414,512 |
| Five leaf variables, standard requested collection | 1.60 s | 1.35 GB | 214,320 |
| Same five variables, wide table | 0.39 s | 0.24 GB | 42,864 |

The original script at commit `5f82e61` would produce 33,948,288 long rows
over 24 hours. Its scene included duplicate stem geometry and senescent sections
in physiology; the table above is a collection benchmark, not a scientific
comparison with the corrected scene.

The corrected full scene has 63,186 objects, 46,465 geometric objects,
14,288 active leaf sections and 304 plants. The complete 2025-07-02 simulation
took 105.52 s in the restarted Kaimon process. Collection took
1.11 s for the earlier five-variable leaf table, 5.16 s for 1,115,160 light rows,
and 0.38 s for 7,296 plant rows. The combined leaf table now has 26 columns,
including MTG identity, physiology, light and derived section fluxes. It collected
342,912 rows in 2.83 s, allocating 1.64 GB in total. Every leaf A, Tₗ, Gₛ
and λE was finite, and no forcing date was missing. Radiation covered Stem,
LeafSection, Panel and Cobblestone objects. Independent table sums for two
plants across all 24 hours matched the plant application, including temperatures,
signed exchanges, duration integration and cumulative quantities. The new merged
table also matched plant rates, step quantities and temperatures for all 7,296
plant timesteps. All leaf, plant and light IDs matched the scene MTG, and the
attached noon light values matched all 46,465 geometric nodes.

897 targeted checks passed against the saved development package in a restarted
Kaimon session.
They cover plant aggregation, retained publications, MTG identity and attachment, geometry
import, original Fvcb dark and low-light behavior, zero respiration, zero
intercept, negative leaf VPD and daytime coupling. A separate 198-case probe
checked finite values and the electron-transport upper bound around compensation.
The full scenario passed authoring validation. These are numerical and structural
checks, not calibration against observations. Plant tables and a leaf time series from the verification run are
in `2_outputs/validation/2026-10-06-output-collection-g0-1e-6/` (ignored generated
data). The earlier verification with the temporary wrapper remains archived
in `2_outputs/validation/2026-10-06-output-collection/`.
Examples with the new node-ID tables are in
`2_outputs/validation/2026-10-06-node-outputs/`: plant outputs, all 24 hours for
one plant's leaf sections, a ground-light snapshot, metrics, and rendered
PlantViz figures for leaf assimilation and ground PAR. Current comma-delimited
and legacy semicolon-delimited CSV-to-node dictionaries were both verified.

The CSV reconstruction workflow passed 40 additional checks for rotations,
world-space mesh equality, saved configuration values, partial table loading,
changed sources/CSVs and inconsistent node identities. A small full-day run
(4 plants) wrote and reloaded 4,512 leaf rows, 13,944 light rows and 96 plant
rows with exactly equal values and geometry; reload took 0.77 s. Its CSVs,
scene recipe and verification metrics are in
`2_outputs/validation/2026-10-06-csv-reload/`.
