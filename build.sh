#!/bin/bash

set -euo pipefail

stage=${1:-alpha}

version_mainline=$(grep "Version: " GigaTwitchEmotes-Mainline.toc | cut -d ' ' -f 3)
version_classic=$(grep "Version: " GigaTwitchEmotes-Classic.toc | cut -d ' ' -f 3)

[ "$version_mainline" == "$version_classic" ] || {
    echo "Error: GigaTwitchEmotes-Mainline.toc is version $version_mainline, but GigaTwitchEmotes-Classic.toc is version $version_classic"
    exit 1
}

version="$version_mainline-$stage"

dist_root="dist"
dist_dir="$dist_root/GigaTwitchEmotes"
zip_name="$dist_root/GigaTwitchEmotes-$version.zip"

rm -rf "$dist_root"
mkdir -p "$dist_dir"
mkdir "$dist_dir/emotes"
for img in emotes/*.webp ; do magick "$img" "$dist_dir/${img%.*}.tga" ; done
cp *.lua "$dist_dir"
cp GigaTwitchEmotes-Mainline.toc "$dist_dir"
cp GigaTwitchEmotes-Classic.toc "$dist_dir"

powershell Compress-Archive "$dist_dir" "$zip_name"
