#!/bin/bash

set -euo pipefail

image="emotes/$2.webp"

size=${3:-32}

if [ $# -eq 2 ]; then
  extension_width=28
else
  extension_width=${size}
fi

url=$(echo "$1" | sed "s/size=[[:digit:]]\+/size=$size/")
curl "$url" -o "emotes/$2.webp"


magick "$image" -background none -gravity center -resize "${size}x32" "$image"
newline='["'$2'"] = basePath .. "'$2'.tga:28:'$extension_width'",'

# Insert before the last line (before the closing bracket)
sed -i -e '$i\'"    $newline" emotes.lua
