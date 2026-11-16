#!/usr/bin/env bash

set -euo pipefail

source .env

if (( $# < 2 )); then
    echo "Usage: $0 <url> <emote_name> [frame_sampling frame_offset]" >&2
    exit 1
fi

url=$1
name=$2
frame_sampling=${3:-1}
frame_offset=${4:-0}

FRAME_HEIGHT=32
DISPLAY_HEIGHT=28
FRAMERATE=18

if [[ ! $name =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "Invalid emote name: $name" >&2
    exit 1
fi

if ! [[ $frame_sampling =~ ^[0-9]+$ && $frame_offset =~ ^[0-9]+$ ]] \
    || (( frame_sampling < 1 )); then
    echo "Invalid frame sampling or offset" >&2
    exit 1
fi

next_power_of_two() {
    local n=$1
    local p=1

    while (( p < n )); do
        (( p *= 2 ))
    done

    echo "$p"
}

mkdir -p emotes
rm -rf import
mkdir -p import

source_image="import/${name}.webp"
stacked_image="import/${name}-stacked.png"
final_image="emotes/${name}.tga"

# Download source animation.
curl -fL "$url" -o "$source_image"

# Extract individual frames.
anim_dump -folder import "$source_image"

shopt -s nullglob
all_frames=(import/dump_*.png)

if (( ${#all_frames[@]} == 0 )); then
    echo "No frames extracted" >&2
    exit 1
fi

# Select frames using sampling and offset.
frames=()

for (( i=frame_offset; i<${#all_frames[@]}; i+=frame_sampling )); do
    frames+=("${all_frames[i]}")
done

num_frames=${#frames[@]}

if (( num_frames == 0 )); then
    echo "No frames selected" >&2
    exit 1
fi

# Read source dimensions from the first selected frame.
read -r source_w source_h < <(
    magick identify -ping -format '%w %h' "${frames[0]}"
)

if (( source_w == 0 || source_h == 0 )); then
    echo "Invalid source dimensions" >&2
    exit 1
fi

# Scale to 32px height while preserving aspect ratio.
# Round width to the nearest multiple of 2.
frame_h=$FRAME_HEIGHT
frame_w=$(( (source_w * frame_h + source_h) / (2 * source_h) * 2 ))

(( frame_w < 2 )) && frame_w=2

# Resize and vertically stack selected frames.
magick "${frames[@]}" \
    -resize "${frame_w}x${frame_h}!" \
    -append "$stacked_image"

# Pad the texture height to the next power of two.
sheet_h=$(( num_frames * frame_h ))
texture_h=$(next_power_of_two "$sheet_h")

# Texture width must match frame width.
texture_w=$frame_w

magick "$stacked_image" \
    -background none \
    -gravity NorthWest \
    -extent "${texture_w}x${texture_h}" \
    "$final_image"

# Calculate display dimensions at 28px height.
display_w=$(( (frame_w * DISPLAY_HEIGHT + frame_h / 2) / frame_h ))

# Register emote in emotes.lua.
emote_entry="    [\"${name}\"] = basePath .. \"${name}.tga:${display_w}:${DISPLAY_HEIGHT}\","

sed -i "/^}/i\\${emote_entry}" emotes.lua

# Register animation metadata.
printf 'TwitchEmotes_animation_metadata[basePath .. "%s.tga"] = {["nFrames"] = %d, ["frameWidth"] = %d, ["frameHeight"] = %d, ["imageWidth"] = %d, ["imageHeight"] = %d, ["framerate"] = %d}\n' \
    "$name" \
    "$num_frames" \
    "$frame_w" \
    "$frame_h" \
    "$texture_w" \
    "$texture_h" \
    "$FRAMERATE" >> animation.lua

echo
echo "Imported: $name"
echo "Frames: $num_frames"
echo "Frame dimensions: ${frame_w}x${frame_h}"
echo "Texture dimensions: ${texture_w}x${texture_h}"
echo "Display dimensions: ${display_w}x${DISPLAY_HEIGHT}"
echo "Output: $final_image"
