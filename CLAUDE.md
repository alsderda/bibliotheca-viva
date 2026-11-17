# Notes for Claude

- **Bump the version in every PR:** run `scripts/dev/bump_version.sh` (patch number +1, version code +10 in both
  places), unless there's a reason not to; say why in the PR. See "Versions" in docs/DEVELOPMENT.md.
- **No site code in the core:** support for a site always goes into a plugin repo (see PLUGINS.md), never into this
  repo.
- **Running Godot from the shell:** use the `godot-headless` skill if you have it. Headless Godot
  (`/Applications/Godot.app/Contents/MacOS/Godot` on macOS) hangs when a script fails to compile, so wrap every run in
  a time limit, e.g. `perl -e 'alarm 60; exec @ARGV' "$G" --headless --path . ...`, and treat a killed run as a
  failure. `--check-only --script` doesn't load autoloads, so "Identifier not found" for one of them is a false alarm.
