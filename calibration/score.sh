#!/bin/bash
# Mean/worst OKLab distance (x100) between GradePreview's prediction and PhotoLab's export, per experiment.
cd "$(dirname "$0")/.."
TOOL_DIR="${TMPDIR:-/tmp}/coloranalyze-calibration-tool"; mkdir -p "$TOOL_DIR"
swiftc -O -module-name calib calibration/tool/main.swift Sources/ColorCore/*.swift -o "$TOOL_DIR/analyze" || exit 1
T="$TOOL_DIR/analyze"; B=calibration/exports/E0-baseline.csv; X=calibration/exports
echo "E1 shadows 231/100   : $($T score $B $X/E1-shadows-231-100.csv --shadows 231,100)"
echo "E2 midtones 231/100  : $($T score $B $X/E2-midtones-231-100.csv --midtones 231,100)"
echo "E3 highlights 231/100: $($T score $B $X/E3-highlights-231-100.csv --highlights 231,100)"
echo "E4 36/312/104@50     : $($T score $B $X/E4-combo.csv --shadows 36,100 --midtones 312,100 --highlights 104,50)"
echo "E5 0/160/270         : $($T score $B $X/E5-combo2.csv --shadows 0,100 --midtones 160,100 --highlights 270,100)"
echo "E6 80/200/340        : $($T score $B $X/E6-combo3.csv --shadows 80,100 --midtones 200,100 --highlights 340,100)"
echo "E7 sat 50/25/75 @231 : $($T score $B $X/E7-sat-231.csv --shadows 231,50 --midtones 231,25 --highlights 231,75)"
echo "E8 hold-out 20/120/250 @70/40/90 (hues and saturations not used in the fit): $($T score $B $X/E8-holdout.csv --shadows 20,70 --midtones 120,40 --highlights 250,90)"
echo "E9 HSL red +25.6 green +28.6 cyan -19.2 blue +27.1 magenta -27.1 (hue turns): $($T score $B $X/E9-hsl.csv --shift red:25.5866,green:28.5536,cyan:-19.2093,blue:27.1425,magenta:-27.1258)"

H=calibration/exports
ALT="red:80,orange:-80,yellow:80,green:-80,cyan:80,blue:-80,purple:80,magenta:-80"
ALTL="red:60,orange:-60,yellow:60,green:-60,cyan:60,blue:-60,purple:60,magenta:-60"
echo "F1 master 231/100          : $($T score $B $H/F1-master-231-100.csv --master 231,100)"
echo "R1 master 36/100           : $($T score $B $H/R1-master-36-100.csv --master 36,100)"
echo "F2 master Luminance +60    : $($T score $B $H/F2-master-lum60.csv --master 0,0,60)"
echo "F3 shadows Luminance +60   : $($T score $B $H/F3-shadows-lum60.csv --shadows 0,0,60)"
echo "F4 midtones Luminance +60  : $($T score $B $H/F4-mids-lum60.csv --midtones 0,0,60)"
echo "F5 highlights Luminance +60: $($T score $B $H/F5-highs-lum60.csv --highlights 0,0,60)"
echo "B1 shadows 231/100, Balance +59.4 : $($T score $B $H/B1-shadows-bal-pos.csv --shadows 231,100 --balance 59.4377)"
echo "B2 shadows 231/100, Balance -59.4 : $($T score $B $H/B2-shadows-bal-neg.csv --shadows 231,100 --balance -59.4377)"
echo "B5 midtones 231/100, Balance +59.4: $($T score $B $H/B5-mids-bal-pos.csv --midtones 231,100 --balance 59.4377)"
echo "B6 midtones 231/100, Balance -59.4: $($T score $B $H/B6-mids-bal-neg.csv --midtones 231,100 --balance -59.4377)"
echo "B3 highlights 231/100, Balance +59.4: $($T score $B $H/B3-highs-bal-pos.csv --highlights 231,100 --balance 59.4377)"
echo "B4 highlights 231/100, Balance -59.4: $($T score $B $H/B4-highs-bal-neg.csv --highlights 231,100 --balance -59.4377)"
echo "H1 HSL Saturation +-80 alternating: $($T score $B $H/H1-hsl-sat.csv --hsl-sat $ALT)"
echo "H2 HSL Luminance +-60 alternating : $($T score $B $H/H2-hsl-lum.csv --hsl-lum $ALTL)"
for h in 0 58 80 104 130 160 200 270 312 340; do
echo "M master $h/100            : $($T score $B $H/M-master-$h-100.csv --master $h,100)"
done
echo "T Blacks +100              : $($T score $B $H/T-blacks-100.csv --tone-blacks 100)"
echo "T Blacks -100              : $($T score $B $H/T-blacks-m100.csv --tone-blacks -100)"
echo "T Blacks +50               : $($T score $B $H/T-blacks-50.csv --tone-blacks 50)"
echo "T Shadows +100             : $($T score $B $H/T-shadows-100.csv --tone-shadows 100)"
echo "T Shadows -100             : $($T score $B $H/T-shadows-m100.csv --tone-shadows -100)"
echo "T Shadows +50              : $($T score $B $H/T-shadows-50.csv --tone-shadows 50)"
echo "T Shadows +40 + Blacks +60 : $($T score $B $H/T-combo-s40-b60.csv --tone-shadows 40 --tone-blacks 60)"
