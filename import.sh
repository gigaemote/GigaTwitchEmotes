#!/usr/bin/env bash

set -euo pipefail

if (( $# != 2 )); then
    echo "Usage: $0 <url> <emote_name>" >&2
    exit 1
fi

url=$1
name=$2

FRAME_HEIGHT=32
DISPLAY_HEIGHT=28

if [[ ! $name =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "Invalid emote name: $name" >&2
    exit 1
fi

mkdir -p emotes

source_image="emotes/${name}-source.webp"
final_image="emotes/${name}.webp"

# Download original image without modifying its dimensions.
curl -fL "$url" -o "$source_image"

# Read original dimensions without relying on newline-terminated output.
source_w=$(magick identify -ping -format '%w' "$source_image")
source_h=$(magick identify -ping -format '%h' "$source_image")
source_w=${source_w//$'\r'/}
source_h=${source_h//$'\r'/}

if ! [[ $source_w =~ ^[0-9]+$ && $source_h =~ ^[0-9]+$ ]] \
    || (( source_w == 0 || source_h == 0 )); then
    echo "Invalid source dimensions" >&2
    exit 1
fi

# Calculate width at 32px height.
# Round to nearest multiple of 2.
frame_w=$(( (source_w * FRAME_HEIGHT + source_h) / (2 * source_h) * 2 ))

(( frame_w < 2 )) && frame_w=2

# Resize to exact dimensions; build.sh converts this WebP to TGA.
magick "$source_image" \
    -background none \
    -resize "${frame_w}x${FRAME_HEIGHT}!" \
    "$final_image"

# Calculate display width at 28px height.
display_w=$(( (frame_w * DISPLAY_HEIGHT + FRAME_HEIGHT / 2) / FRAME_HEIGHT ))

# Register packaged TGA emote.
emote_entry="    [\"${name}\"] = basePath .. \"${name}.tga:${display_w}:${DISPLAY_HEIGHT}\","

sed -i "/^}/i\\${emote_entry}" emotes.lua

# Remove temporary source image.
rm "$source_image"

echo
echo "Imported: $name"
echo "Source dimensions: ${source_w}x${source_h}"
echo "Texture dimensions: ${frame_w}x${FRAME_HEIGHT}"
echo "Display dimensions: ${display_w}x${DISPLAY_HEIGHT}"
echo "Output: $final_image"

