# PhotoLab White Balance on a RAW (4 November 2026, PhotoLab 10.1)

One OM-1 Mark II RAW (`OM1R5761.ORF`, a windsurfer against water), opened in PhotoLab, only White Balance changed, exported as
16-bit TIFF. As Shot in PhotoLab: **Temperature 5694 K, Tint −13** (macOS' `CIRAWFilter` reads 4974 K / +3.7 from the same
file, so the two cannot be mixed). `measure.py` compares each export with the 5694 K one: the median per-pixel gain per channel
(linear sRGB, midtones only), which is where the photo's grey went, in mired and in 3000 × Δuv on the Planckian locus.

| Setting | Gains R, G, B | Grey moved | Slider moved |
|---|---|---|---|
| 5694 → 4500 K | 0.768, 1, 1.215 | −41.1 mired | +46.6 mired |
| 5694 → 7000 K | 1.140, 1, 0.858 | +27.6 mired | −32.7 mired |
| Tint −13 → +30 (43 steps) | 1.232, 1, 1.230 | 36 (3000 × Δuv, toward magenta) | 43 steps |

So the Temperature slider acts on the photo's grey as a shift of **0.86 mired per mired** of its Kelvin value (0.88 and 0.84), opposite
in sign (a lower Kelvin value cools the photo), and the Tint moves it by about **0.84 × 3000 Δuv per step** (36 over the 43 steps from −13 to +30). Used in `WhiteBalanceCorrection`.

Limits: one photo, one camera; the per-pixel gains scatter (blue up to 19 %), so the factors are good to perhaps 10 %. The Tint
step was taken from −13 to +30, the Tint axis was not measured on the other side or at another temperature.
