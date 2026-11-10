#!/bin/sh
# Raises the version for a PR (see "Versions" in docs/DEVELOPMENT.md): patch number of config/version +1, and the
# version code +10 in both project.godot and export_presets.cfg. Run from the repo root.
# Usage: scripts/dev/bump_version.sh
set -eu

name=$(sed -n 's/^config\/version="\(.*\)"$/\1/p' project.godot)
code=$(sed -n 's/^config\/version_code=\([0-9]*\)$/\1/p' project.godot)
preset=$(sed -n 's/^version\/code=\([0-9]*\)$/\1/p' export_presets.cfg)

if [ -z "$name" ] || [ -z "$code" ] || [ -z "$preset" ]; then
	echo "bump_version: couldn't read the version from project.godot or export_presets.cfg" >&2
	exit 1
fi
if [ "$code" != "$preset" ]; then
	echo "bump_version: version codes differ (project.godot $code, export_presets.cfg $preset); fix that first" >&2
	exit 1
fi

new_name=$(echo "$name" | awk -F. -v OFS=. '{ $NF = $NF + 1; print }')
new_code=$((code + 10))

perl -pi -e "s/^config\/version=\".*\"\$/config\/version=\"$new_name\"/; s/^config\/version_code=\\d+\$/config\/version_code=$new_code/" project.godot
perl -pi -e "s/^version\/code=\\d+\$/version\/code=$new_code/" export_presets.cfg

echo "version $name -> $new_name, code $code -> $new_code"
