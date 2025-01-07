#!/bin/bash

set -x

FN=$(command date "+%F %H%M%S")

output_dir=out
mkdir -p "${output_dir}"
cd $output_dir

echo hello >"$FN"
mkdir subdir
echo hello >"subdir/$FN"
