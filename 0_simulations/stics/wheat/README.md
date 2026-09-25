# Spring-sown Neodur, Montpellier 2025

This is a JavaSTICS workspace containing one USM, `neodur_2025`, adapted
from the `DurumWheat` (Acalou) example supplied with JavaSTICS 10.5.0.

## Configuration

| Setting | Value |
|---|---|
| Simulation period | 1 January–31 December 2025 (`datedebut=1`, `datefin=365`) |
| Crop duration option | One calendar year (`culturean=1`) |
| Plant file | `plant/DurumWheat_NEODUR_plt.xml`, copied without changes |
| Cultivar | Neodur, index 1, `jvc=0` |
| Sowing | 15 February, day 46; 268 seeds/m²; depth 3 cm |
| Climate | `montpellier.2025`, generated from `0_simulations/meteo/meteo_data_2025_montpellier.csv` |
| Station | Montpellier, latitude 43.61°; wind reference height 2 m |
| PET | Calculated by STICS using Penman (`codeetp=2`) |
| Irrigation | None, as in the Acalou example |
| Phenology | Simulated; no imposed stage dates or observed LAI |
| Harvest | Original grain-water-content rule, with latest date set to day 365 |

## Management and soil assumptions

The soil `solbldur` and its matching `bledur_ini.xml` are kept from the Acalou
example. Its initial soil water and mineral nitrogen values are used as assumed
1 January conditions. These are **example inputs, not measured Montpellier soil
conditions**. The initial crop state is bare soil (`stade0=snu`).

Residue input (1 t/ha, with the original composition) and tillage (22 cm) are
scheduled on **14 February, day 45**, before sowing. Fertilizer amounts and type
are kept from Acalou: 196 kg N/ha in total, fertilizer code 2. The first
application is moved to sowing, preserving the original intervals between
applications:

| Application date | Day of year | Nitrogen (kg N/ha) |
|---|---:|---:|
| 15 February | 46 | 20 |
| 13 March | 72 | 86 |
| 18 April | 108 | 55 |
| 5 May | 125 | 35 |

The station is adapted from the original wheat workspace's `climblej_sta.xml`.

## Run

From the repository root:

```sh
Rscript 1_code/1_stics_simulations.R
```

This runs `neodur_2025` in `0_simulations/stics/wheat`, writes
`simulations_stics_wheat.csv` in this workspace, and saves the plot to
`2_outputs/stics_wheat.png`. The converter's missing-observation message is
expected: this scenario has no measured observations.
