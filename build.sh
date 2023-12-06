#!/bin/bash

set -euo pipefail

version=$(grep "Version: " TwitchEmotes_Coomer.toc | cut -d ' ' -f 3)

dist_dir="dist/TwitchEmotes_Coomer"
zip_name="dist/TwitchEmotes_Coomer-$version.zip"

rm -rf "$dist_dir"
mkdir -p "$dist_dir"
cp -r emotes "$dist_dir"
cp emotes.lua "$dist_dir"
cp main.lua "$dist_dir"
cp TwitchEmotes_Coomer.toc "$dist_dir"

powershell Compress-Archive "$dist_dir" "$zip_name"
