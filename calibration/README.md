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

### To measure next: the rest of the Light palette (requested 4 November 2026)

Why: the intention's *light–dark* contrast cannot be raised with what is modeled now. Deeper Blacks darken the midtones too in the model, and raising Shadows to make up for it lifts the deepest blacks even more, so the tonal range shrinks instead of growing. A real S-curve needs the other end as well, Whites and Highlights, plus Midtones and the Contrast slider, and none of these were measured. A second point for Blacks and Shadows at −50 checks whether the negative side is as linear as the model assumes (only −100 was measured there, and it clipped).

**Before you start.** Open `chart.jpg` in PhotoLab 10 with every correction off: DxO Smart Lighting, ClearView Plus, Contrast, Color Grading, HSL, Vignetting, Lens Sharpness and the rest. Use the same export as before: *Image ▸ Export to ▸ Disk*, TIFF 16-bit, full size, no resizing, sRGB, to `~/Pictures/ColorAnalyze Calibration/chart.tif`. Build the tool once with `./calibration/score.sh`, then file each export with `./calibration/harvest.sh NAME` straight after it. Reset everything between exports. Leave Microcontrast and Fine Contrast at 0; they are local and a chart of flat patches cannot measure them.

| Name | Palette | Setting (everything else 0) | Why |
|---|---|---|---|
| `T0-check` | — | nothing (the unedited chart) | must equal `E0-baseline`; if it does not, something else is still on |
| `T-whites-100` | Light ▸ Selective Tone | Whites +100 | the light end of the curve |
| `T-whites-m100` | Light ▸ Selective Tone | Whites −100 | |
| `T-whites-50` | Light ▸ Selective Tone | Whites +50 | is it linear? |
| `T-highlights-100` | Light ▸ Selective Tone | Highlights +100 | |
| `T-highlights-m100` | Light ▸ Selective Tone | Highlights −100 | |
| `T-highlights-50` | Light ▸ Selective Tone | Highlights +50 | |
| `T-midtones-100` | Light ▸ Selective Tone | Midtones +100 | |
| `T-midtones-m100` | Light ▸ Selective Tone | Midtones −100 | |
| `T-midtones-50` | Light ▸ Selective Tone | Midtones +50 | |
| `T-blacks-m50` | Light ▸ Selective Tone | Blacks −50 | the negative side between 0 and the clipped −100 |
| `T-shadows-m50` | Light ▸ Selective Tone | Shadows −50 | the same for Shadows |
| `K-contrast-50` | Light ▸ Contrast | Contrast +50 | the global contrast slider |
| `K-contrast-100` | Light ▸ Contrast | Contrast +100 | is it linear? |
| `K-contrast-m50` | Light ▸ Contrast | Contrast −50 | |
| `T-scurve` | Light ▸ Selective Tone | Blacks −40, Shadows −20, Highlights +30, Whites +20 | hold-out: an S-curve built from the single sliders, to check that they add up |
| `T-scurve-color` | Light ▸ Selective Tone + Color Grading | `T-scurve` plus Color Grading Highlights Hue 36 / Sat 40 and Shadows Hue 231 / Sat 40 | the order of the two tools: the preview applies Selective Tone first |

Seventeen exports. If the Contrast slider turns out to depend on the image (an adaptive curve), it will show as a mismatch between `K-contrast-50` on the chart and on a photo. In that case it stays advice in the app, not a lever.

**Measured on 4 November 2026** (PhotoLab 10, exports driven by Claude through macOS accessibility; `T0-check` equals `E0-baseline` byte for byte). Change of the grey ramp in OKLab L × 100, against the unedited chart (baseline row):

| grey patch | 0 | 2 | 4 | 6 | 8 | 10 | 12 | 14 | 16 |
|---|---|---|---|---|---|---|---|---|---|
| baseline | 0 | 24 | 37 | 49 | 60 | 71 | 81 | 91 | 100 |
| Whites +100 | 0 | +6 | +10 | +14 | +18 | +21 | +19 | +9 | 0 |
| Whites +50 | 0 | +2 | +4 | +6 | +8 | +9 | +10 | +9 | 0 |
| Whites −100 | 0 | −3 | −5 | −7 | −8 | −10 | −12 | −13 | −15 |
| Highlights +100 | 0 | +1 | +4 | +10 | +19 | +23 | +17 | +8 | 0 |
| Highlights +50 | 0 | 0 | +2 | +4 | +7 | +11 | +10 | +6 | 0 |
| Highlights −100 | 0 | −1 | −3 | −6 | −10 | −15 | −20 | −24 | 0 |
| Midtones +100 | 0 | 0 | +6 | +14 | +17 | +12 | +5 | 0 | 0 |
| Midtones +50 | 0 | 0 | +3 | +7 | +8 | +6 | +2 | 0 | 0 |
| Midtones −100 | 0 | 0 | −6 | −15 | −18 | −13 | −5 | 0 | 0 |
| Blacks −50 | 0 | −24 | −14 | −10 | −8 | −5 | −4 | −2 | 0 |
| Blacks −100 (October) | 0 | −24 | −37 | −26 | −19 | −14 | −9 | −4 | 0 |
| Shadows −50 | 0 | −9 | −14 | −13 | −7 | −3 | −1 | 0 | 0 |
| Shadows −100 (October) | 0 | −17 | −23 | −29 | −20 | −9 | −3 | −1 | 0 |
| Contrast +50 | 0 | −3 | −3 | −2 | 0 | +2 | +2 | +2 | 0 |
| Contrast +100 | 0 | −7 | −7 | −4 | 0 | +4 | +5 | +4 | 0 |
| Contrast −50 | 0 | +3 | +3 | +2 | 0 | −2 | −2 | −2 | 0 |
| S-curve (B −40, S −20, H +30, W +20) | 0 | −20 | −14 | −11 | −3 | +4 | +8 | +6 | 0 |

First readings:
- **The S-curve does stretch the tonal range**: the darks go down by up to 20 and the lights up by up to 8. That is what the Blacks-only model could not do.
- **Blacks −50 stays much more in the darks than half of −100.** It crushes the darkest patch as far as −100 does, but it reaches the midtones only half as much. The linear interpolation in the current model is therefore wrong on the negative side.
- **The other sliders are about symmetric and linear**, with clipping at the ends.
- **Contrast is a mild, symmetric S around the middle grey.**
- **`T-scurve-color`** adds Color Grading Highlights 36/40 and Shadows 231/40 on top of the S-curve. It still has to be scored for the order of the two tools.

While the exports were made, stray keystrokes reached PhotoLab's image browser twice. They wrote a star rating of 0 into the XMP of `chart.jpg` and `spanje.jpg` in `~/Pictures/ColorAnalyze Calibration`; the pixels are unchanged, as the chart's dump shows. They also exported `spanje.tif` once, which was removed. `K-contrast-50` was exported while both images were selected, but the chart export itself is valid.

**What was done with them** (4 November 2026). `emit_extra.py` now writes `GradePreviewToneTable.swift` with every slider at every measured amount, and the preview interpolates between them. `score.sh` scores each export.
- **Model choice.** Two models were tried on the colored patches: gain by the mean, and one curve per channel. Gain by the mean, clipped at white, fits Selective Tone best (Blacks −50 0.8 against 7.1; Midtones −100 1.8 against 9.5). Lifts of Highlights and Whites stay at about 40 % of the effect (5.4 against 12.5). A curve per channel fits Contrast best (0.6 against 2.3).
- **Adding versus composing.** Added up, the four sliders of `T-scurve` miss by 2.2 on the greys (effect 8.0). Composed one after another they do better: the order Shadows, Blacks, Whites, Highlights fits best, at 1.6. The remaining error is probably a non-linearity between 0 and ±50 that two more points per slider would show.
- **S-curve with Color Grading.** `T-scurve-color` scores like `T-scurve` (1.6 grey, 2.7 colors), so applying Selective Tone before Color Grading does no harm here.
- **Use.** The intention steering tries S-curves and Contrast as levers for *light–dark*, and the PhotoLab tab shows them under *Light palette*.
