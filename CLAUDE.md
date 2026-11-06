# Notes for Claude

- **Finish with a PR:** when a task changes files, commit to a branch, push, and open a PR against `main` without
  being asked.
- **Bump the version in every PR:** raise the patch number of `config/version` in `project.godot` by 1, and the
  version code by 10 in both `config/version_code` (`project.godot`) and `version/code` (`export_presets.cfg`), unless
  there's a reason not to (say why in the PR). See "Versions" in docs/DEVELOPMENT.md.
- **No site code in the core:** support for a site always goes into a plugin repo (see PLUGINS.md), never into this
  repo.
- **Running Godot from the shell:** headless Godot (`/Applications/Godot.app/Contents/MacOS/Godot`) hangs instead of
  exiting when a `--script` file or anything it loads fails to compile. macOS has no `timeout`, so wrap every run in a
  limit, e.g. `perl -e 'alarm 60; exec @ARGV' "$G" --headless --path . ...`, and treat a killed run as a failure.
  `--check-only --script` doesn't load autoloads, so "Identifier not found" for one of them is a false alarm.
