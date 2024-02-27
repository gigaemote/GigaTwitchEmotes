#!/bin/bash

set -euo pipefail

source .env

stage=${1:-alpha}

version_mainline=$(grep "Version: " GigaTwitchEmotes-Mainline.toc | cut -d ' ' -f 3)
version_classic=$(grep "Version: " GigaTwitchEmotes-Classic.toc | cut -d ' ' -f 3)

[ "$version_mainline" == "$version_classic" ] || {
    echo "Error: GigaTwitchEmotes-Mainline.toc is version $version_mainline, but GigaTwitchEmotes-Classic.toc is version $version_classic"
    exit 1
}

version="$version_mainline-$stage"

[[ -z $(git status -s) ]] || {
    echo "Error: Not all changes committed"
    exit 1
}

git merge-base --is-ancestor HEAD @{u} || {
    echo "Error: Not all commits merged"
    exit 1
}

./build.sh "$stage"

git tag -f -a "$version" -m "$version"
git push origin --tags "$version"

gh release create \
    "$version" \
    --verify-tag \
    --title "$version" \
    --notes "$version" \
    "dist/GigaTwitchEmotes-$version.zip"

echo "Published version $version to GitHub"

# Get version numbers from running this, they're likely at the end of the list.
# (. .env && curl  -H "X-Api-Token: $CURSEFORGE_API_TOKEN" https://wow.curseforge.com/api/game/versions)

#metadata=$(cat <<EOF
#{
#    "changelog": "$version",
#    "displayName": "$version",
#    "gameVersions": [10341, 10372],
#    "releaseType": "$stage"
#}
#EOF
#)

#curl \
#    -H "X-Api-Token: $CURSEFORGE_API_TOKEN" \
#    -F metadata="$metadata" \
#    -F file="@dist/TwitchEmotes_Coomer-$version.zip" \
#    https://wow.curseforge.com/api/projects/947149/upload-file
#
#echo "Published version $version to CurseForge"
