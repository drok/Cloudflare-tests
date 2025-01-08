#!/bin/bash

set -x

FN=$(command date "+%F %H%M%S")

output_dir=out
mkdir -p $output_dir/subdir

deterministic_version() {
    # Reference date in YYYY-MM-DD format
    local REFERENCE_DATE="2024-12-01"

    # Get current date
    local CURRENT_DATE=$(date +"%Y-%m-%d")

    # Calculate difference in months
    local ref_year=$(date -d  "$REFERENCE_DATE" +%Y)
    local ref_month=$(date -d "$REFERENCE_DATE" +%m)
    local cur_year=$(date -d  "$CURRENT_DATE" +%Y)
    local cur_month=$(date -d "$CURRENT_DATE" +%m)
    version_major=$((cur_year*12 + cur_month - ref_year*12 - ref_month))

}

pastel_colors=(
  "#FFC5C5" "#FFB6C1" "#FF99CC" "#FF7FBF" "#FF66B3" "#FF4C9F" "#FF33A1" "#FF1A85"
  "#E6DAC3" "#E6C9C5" "#E6B8B8" "#E69FA1" "#E67F8A" "#E65E73" "#E63C5C" "#E61945"
  "#C5E1F5" "#C5C9F1" "#C5B3EC" "#C59FE6" "#C577E0" "#C54DDC" "#C43BC8" "#C3A5C4"
  "#F7D2C4" "#F2B9A6" "#ECA289" "#E7A17A" "#E4946D" "#E2815F" "#DF6F50" "#DD5C41"
)

# Create versioned assets
deterministic_version

sed '
    s/_STYLES_FILE_/'styles.v"$version_major".css'/;
    s/_VERSION_/'v"$version_major"'/;
    ' <index.html > $output_dir/index.html

sed '
    s/_BACKGROUND_COLOR_/'"${pastel_colors[$((version_major % 32))]}"'/;
    ' <styles.css > $output_dir/styles.v"$version_major".css

cp $output_dir/styles.v"$version_major".css $output_dir/subdir
echo "This unversioned file was last generated on $(date) (with v$version_major release)"> $output_dir/subdir/unversioned-file
# cp styles.css $output_dir/styles.v"$version_major".css