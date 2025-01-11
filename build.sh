#!/bin/bash

NOW=$(date +%s)
date() {
	command date --date=@$NOW "$@"
}

FN=$(date "+%F-%H%M%S")

output_dir=out
mkdir -p $output_dir/subdir $output_dir/edge-cached-1-minute

deterministic_version() {
    # Reference date in YYYY-MM-DD format
    local REFERENCE_DATE="2024-12-01"

    # Get current date
    local CURRENT_DATE=$(date +"%Y-%m-%d")

    # Calculate difference in months
    local ref_year=$(command date -d  "$REFERENCE_DATE" +%Y)
    local ref_month=$(command date -d "$REFERENCE_DATE" +%m)
    local cur_year=$(command date -d  "$CURRENT_DATE" +%Y)
    local cur_month=$(command date -d "$CURRENT_DATE" +%m)
    version_major=$((cur_year*12 + cur_month - ref_year*12 - ref_month))
}

pastel_colors=(
    "#ffcbc3" "#a1c9f2" "#ffd7be" "#c9e4ca" "#ffe6cc" "#b2e6ce" "#d2b4fc" "#c5cae9"
)

# Create versioned assets
deterministic_version

# Generate color swatch
generate_color_swatch() {
    COLOR_SWATCH_BOX=""
    local color
    for i in "${!pastel_colors[@]}"; do
        color=${pastel_colors[i]}
        if (( i == (version_major % ${#pastel_colors[@]}) )); then
            class="swatch active-swatch"
        else
            class="swatch"
        fi
        COLOR_SWATCH_BOX+="<div class=\"$class\" style=\"background-color: $color;\"><b>$i</b></div>\n"
    done
}
generate_color_swatch

entry_points=(index.html offline.html)
for f in ${entry_points[@]} ; do 
sed '
    s/_STYLES_FILE_/'styles.v"$version_major".css'/g;
    s/_VERSION_/'v"$version_major"'/g;
    s@_SWATCH_BOX_@'"$COLOR_SWATCH_BOX"'@g;
    ' <$f > $output_dir/$f
done

sed '
    s/_BACKGROUND_COLOR_/'"${pastel_colors[$((version_major % 32))]}"'/g;
    ' <styles.css > $output_dir/styles.v"$version_major".css

cp $output_dir/styles.v"$version_major".css $output_dir/subdir
cp favicon.ico $output_dir
cp -a static $output_dir
cp robots.txt $output_dir

cp checkmark.svg $output_dir/edge-cached-1-minute
echo "This unversioned file was last generated on $(date) (with v$version_major release)"> $output_dir/subdir/unversioned-file
# cp styles.css $output_dir/styles.v"$version_major".css

echo "Generated" > $output_dir/Generated-$FN

# Turn off SPA mode in the subdirectory
echo "File Not Found (404)" > $output_dir/subdir/404.html
echo "File Not Found (404)" > $output_dir/edge-cached-1-minute/404.html

# Generate file listing
cat >$output_dir/subdir/index.html <<!
<!DOCTYPE html>
<html>
<head>
	<title>Code Block</title>
	<style>
		.code-block {
			font-family: monospace;
			background-color: #f7f7f7;
			padding: 10px;
			border: 1px solid #ddd;
			border-radius: 3px;
			width: 90%;
			margin: 10px auto;
		}
	</style>
</head>
<body>
	<pre class="code-block">
!
find $output_dir -type f -ls >>$output_dir/subdir/index.html | sort -n
cat >>$output_dir/subdir/index.html <<!
	</pre>
</body>
</html>
!

find $output_dir -type f -ls | sort -n > $output_dir/subdir/generated.txt
