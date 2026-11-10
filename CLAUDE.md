# Notes for Claude

- **Finish with a PR:** when a task changes files, commit to a branch, push, and open a PR against `main` without
  being asked. Then wait for the PR's CI checks to finish and look at what they report. If a check fails, fix it and
  push again before handing back.
- **Bump the version in every PR:** run `scripts/dev/bump_version.sh` (patch number +1, version code +10 in both
  places), unless there's a reason not to; say why in the PR. See "Versions" in docs/DEVELOPMENT.md.
- **No site code in the core:** support for a site always goes into a plugin repo (see PLUGINS.md), never into this
  repo.
- **Running Godot from the shell:** use the `godot-headless` skill if you have it. Headless Godot
  (`/Applications/Godot.app/Contents/MacOS/Godot` on macOS) hangs when a script fails to compile, so wrap every run in
  a time limit, e.g. `perl -e 'alarm 60; exec @ARGV' "$G" --headless --path . ...`, and treat a killed run as a
  failure. `--check-only --script` doesn't load autoloads, so "Identifier not found" for one of them is a false alarm.
