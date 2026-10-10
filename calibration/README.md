# Calibrating the preview against DxO PhotoLab

What is in here, and how the numbers in the README came about. Measured with PhotoLab 10.1.0.32.

| File | What it is |
|---|---|
| `chart.jpg`, `makechart.swift`, `manifest.csv` | The test chart (3060 × 720): a row of 17 greys and three rows of 17 hues at three saturation/brightness levels. `makechart.swift` generates it; `manifest.csv` lists the patches. |
| `exports/E0-baseline.csv` | The chart as PhotoLab exports it with no corrections (16-bit TIFF): the same colors to within 0.003 in OKLab. |
| `exports/E1 … E9 *.csv` | PhotoLab's export after one grading each, one row per patch (linear sRGB and OKLab, averaged over the middle of the patch). |
| `exports/E9-hsl.dop` | The sidecar of the HSL experiment: the exact Hue values of the handles that were dragged. |
| `tool/main.swift` | `analyze dump` (a chart or export → CSV), `compare`, `score`: measured change per patch next to what `GradePreview` predicts. |
| `score.sh` | Builds the tool and scores `GradePreview` on every experiment. |
| `fit14.py`, `emit_tables.py`, `model_final_inputs.npz` | The fit of the Color Grading curves and hue directions, and the generator of `Sources/ColorCore/GradePreviewTables.swift`. |
| `fit_extra.py`, `emit_extra.py` | Helpers for the second series (Luminance, Master, Balance, HSL), and the generator of `Sources/ColorCore/GradePreviewExtraTables.swift`. |
| `harvest.sh` | Turns PhotoLab's latest export (`chart.tif`) into `exports/NAME.csv` and parks the TIFF. |
| `exploration/` | The scripts that tried other models (additive in sRGB or OKLab, other RGB spaces, brightness measures …) on the way. |

The experiments (Hue / Saturation per range, everything else at 0):

| | Shadows | Midtones | Highlights |
|---|---|---|---|
| E1, E2, E3 | 231 / 100 | – | – (one range at a time) |
| E4 | 36 / 100 | 312 / 100 | 104 / 50 |
| E5 | 0 / 100 | 160 / 100 | 270 / 100 |
| E6 | 80 / 100 | 200 / 100 | 340 / 100 |
| E7 | 231 / 50 | 231 / 25 | 231 / 75 (is Saturation linear?) |
| E8 | 20 / 70 | 120 / 40 | 250 / 90 (hold-out: not used in the fit) |
| E9 | HSL: Red +25.59, Green +28.55, Cyan −19.21, Blue +27.14, Magenta −27.13 (the others 0) | | |

The 16-bit TIFFs themselves (13 MB each) are not kept; the CSVs hold what the fit and the score need. To redo the measurement open `chart.jpg` in PhotoLab, set the values above in the Color Grading and HSL palettes, export each as a 16-bit TIFF (*Image ▸ Export to ▸ Disk*, TIFF 16-bit, full size, no resizing), write the sidecar for the HSL experiment (*File ▸ Sidecars ▸ Export*), and `analyze dump` each file.

The second series (10 October 2026, same PhotoLab 10.1.0.32; HSL reset, Color Grading reset between runs, `H0-check.csv` is the unedited chart again and equals `E0` exactly):

| | Setting |
|---|---|
| F1, R1 | Master 231 / 100 and 36 / 100 |
| F2 | Master Luminance +60 |
| F3, F4, F5, F6 | Shadows, Midtones, Highlights Luminance +60; Highlights −60 (F6, only the greys are valid) |
| B1, B2 | Shadows 231 / 100 at Balance +59.44 and −59.44 (the sidecar says 59.437751) |
| B3, B4 | the same for Highlights |
| B5, B6 | the same for Midtones |
| H1 | HSL Saturation +80 / −80 alternating over red, orange, yellow, green, cyan, blue, purple, magenta |
| H2 | HSL Luminance +60 / −60 alternating |

Two lessons: the first attempt at F1–G2 was contaminated, because the HSL shifts of E9 were still on (the unedited chart is what `H0-check` is for; always export one after a reset); and `G1`/`G2` (the same tint on all three ranges, Balance ±59) came out byte-identical to the Master export `F1`, which says that Balance can only be measured with one range at a time (B1–B6). `G1`/`G2` are those all-ranges exports; the `contaminated-…` files are what the first attempt gave, kept as a warning. `F6` has valid greys only (taken during the first attempt).

### A real photo (11 October 2026)

`analyze photo BASELINE.tif GRADED.tif [flags]` compares what the preview makes of a PhotoLab export of a photo without corrections with PhotoLab's export with them (both 16-bit TIFF, downscaled to 700 px; errors are OKLab distance × 100, per lightness band). Tried on a copy of a Spanish street photo (iPhone, Display P3, 1536 × 2048); PhotoLab's exports are deterministic (two baseline exports are identical, so the errors below are the model's).

| Grading | effect | error | note |
|---|---|---|---|
| Shadows 210/25 | 0.56 | 0.22 | |
| + Midtones 40/20, Highlights 60/15, Balance +29.7 | 0.69 | 0.32 | |
| + HSL Saturation orange +25, blue −30, Luminance green −20 | 1.65 | 0.62 | p95 error 1.1, against effect 4.7 |

By lightness: above OKLab L 0.35 (about 80 % of the pixels) the predicted change points the right way (cosine 0.92–0.97) and is 5–30 % too large (measured = 0.72–0.95 × predicted). Below L 0.25 the model is wrong (cosine 0.2–0.6; the darkest 3 % even has the wrong sign for the a axis); the likely reason is that the TIFF is clipped to sRGB where the photo's P3 colors are not, so very dark saturated pixels have lost information before the comparison starts. Near-black pixels are a small part of a photo and the effect on them is small, but the preview there says little.

**Why the photo is worse than the chart, as far as it could be traced** (11 October 2026). On the chart the same gradings come out much closer: the shadows alone at 210/25 give error 0.07 against an effect of 0.46 (`exports/C2-shadows-210-25.csv`), the whole set of the table above error 0.16 against 0.73 (`C1-like-photo-wheels.csv`); on the photo they give 0.22 and 0.32. So it is not the grading model. What is different with the photo:

- PhotoLab's export of the photo *without* corrections is not the photo: against the source JPEG the mean OKLab distance is 2.4 (p95 7.6), it is on average about 10 % lighter in linear light, and the ratio varies from pixel to pixel (standard deviation 0.2–0.4). The chart is returned unchanged. DxO Smart Lighting, ClearView Plus and Contrast were on by default for the photo, but switching them off changes nothing visible (P0 and P1 are identical to 0.00), and the Color rendering is inactive; what does the rest is not known (camera-specific rendering, colour management of the Display P3 file, or something I did not find).
- The Color Grading change then passes through that unknown step: measured/predicted is about 0.78 for channel values of 0.03–0.25, about 1.3 for 0.25–0.5 and far above 1 for brighter values, in all three channels alike. A global tone curve, a luminance mask, a blurred mask and a plain scale or exposure factor each fail to explain it (rms error 0.0013–0.0022 against 0.0013 for the unchanged model).

The model was therefore **not** changed: fitting it to this photo would make the chart, which is the only clean reference, worse. What this means in use: the preview is a good guide to direction and character, its size is right to within about 30 % for the middle and light tones, and the deep shadows are the least reliable part. A photo that already has DxO corrections of its own (the one in PhotoLab) will deviate more than the unedited chart does.

### Master per hue (10 October 2026)

Master was first modelled with the directions of the ranges and one curve, and was the least exact wheel (hue 36: error 1.7 against an effect of 5.9). It was then measured at eight more hues with Saturation 100 (`exports/M-master-H-100.csv`, H = 0, 80, 104, 160, 200, 270, 312, 340; with `F1` at 231 and `R1` at 36 that is ten hues), and the grey ramp of each gives what the red, green and blue channel get at each node (`GradePreviewMasterTable.swift`, generated by `emit_extra.py`). Master turned out not to be one direction times one curve: each channel has its own curve, and they change with the hue.

Checked by leaving a hue out of the table and predicting it from the others (error of the colored patches against the effect): 104° 2.2 (9.6), 160° 2.9 (9.5), 270° 0.7 (8.1), 340° 1.4 (9.7). Two hues measured afterwards (58° and 130°, then added to the table, so twelve in all) were predicted from the ten before: 58° 1.0 (6.1), 130° 2.2 (10.9). With all twelve in the table the errors at the measured hues are 0.15–1.8 (effect 6–11), the largest for the saturated green and cyan patches (160°, 130°). A grey ramp fixes the curve per channel; saturated colors, where the three channels have very different values, are where the assumption that each channel follows its own curve shows.

### Selective Tone: Blacks and Shadows (10 October 2026)

PhotoLab's *Light* palette has numeric sliders (Whites, Highlights, Midtones, Shadows, Blacks) in the module *Selective Tone*; they were measured for Blacks and Shadows (`exports/T-*.csv`: Blacks +100, −100 and +50, Shadows +100, −100 and +50, and Shadows +40 with Blacks +60), because that is what a *Faded* look needs and what the Color Grading wheels cannot do (their curves are zero at black).

- On greys the operation is a curve: Blacks +100 takes a grey of 0.0052 to 0.047, 0.0144 to 0.069 and 0.162 to 0.259 (linear light), black stays 0, white stays 1; −100 crushes everything below about 0.06 to zero.
- On colors it is not a curve per channel (error 3.0 against an effect of 6.7) but a **gain by the mean of the three channels**: each pixel is scaled by `curve(mean)/mean`, which keeps its hue and chroma (error 1.5; the luminance weights of Rec.709 or Rec.2020 as the "mean" give 2.5–2.7, the maximum of the channels 3.4; an OKLab lightness map with the chroma kept 2.0).
- The sliders are about linear (+50 gives 0.4–0.55 of +100) and add up (the combination is within 10 % of 0.6 × Blacks + 0.4 × Shadows). The table (`GradePreviewToneTable.swift`) holds the +100 and −100 curves; between them the model scales linearly.
- Not measured: Whites, Highlights and Midtones; the Tone Curve; Contrast; the order of these tools against Color Grading (the preview applies them first).
