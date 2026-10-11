# SVG Diagrams for AgriPV Simulation Framework

This directory contains two SVG diagrams illustrating the repository's STICS, Archicrop, scene-building, ArchimedLight, and PlantBioPhysics workflow.

## Files

1. `crop_model_integration.svg` - High-level view of the crop-to-simulation workflow and its outputs.
2. `detailed_integration.svg` - Repository-level view of component inputs, exchanged data, and output files.

Solid arrows show the main processing sequence. The dashed green arrow shows the absorbed-light (`aPPFD`) input passed from ArchimedLight to PlantBioPhysics. There are no feedback-loop arrows: the daily and yearly simulation drivers run the coupled light and physiology models downstream of the STICS-driven plant growth.

## Creation Process

The diagrams use self-contained SVG markup, embedded styles, and arrow markers; no external images, fonts, or scripts are required.

## Usage

The workflow shown is:
1. STICS provides crop growth and phenology used by Archicrop.
2. Archicrop generates date-specific plant maquettes as OBJ and MTG files.
3. `agripv_scene()` combines the maquettes with the PV configuration, planting layout, and ground.
4. ArchimedLight calculates light absorption and provides `aPPFD` to PlantBioPhysics.
5. PlantBioPhysics models leaf physiology and energy balance, then aggregates plant summaries.
6. The simulation writes leaf, light, and plant CSV tables plus a scene recipe.

## Last Updated

October 11, 2026 - Aligned with the workflow in `1_code/`.
