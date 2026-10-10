#!/bin/bash
# harvest.sh NAME — turn PhotoLab's latest export (chart.tif) into calibration/exports/NAME.csv and park the TIFF.
cd "$(dirname "$0")/.."
SRC="$HOME/Pictures/ColorAnalyze Calibration/chart.tif"
T="${TMPDIR:-/tmp}/coloranalyze-calibration-tool/analyze"
"$T" dump "$SRC" > "calibration/exports/$1.csv" && mv "$SRC" "${PARK:-/tmp}/$1.tif"
