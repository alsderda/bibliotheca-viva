---
name: bibliotheca-run
description: How to set up, test and launch Bibliothéca-viva from a fresh checkout or worktree (Godot import, self-test, sync test, plugin test, profiles, plugins folder). Use before running the app, its tests or any of its scripts.
---

# Running Bibliothéca-viva

`$G` below is your Godot 4.7 binary: `G=godot` if it is on the PATH, or on macOS `G=/Applications/Godot.app/Contents/MacOS/Godot`.

## Fresh checkout or worktree

Run this once, before anything else. It builds the `.godot` cache (class names, imported assets) that a fresh checkout does not have.

```sh
perl -e 'alarm 300; exec @ARGV' "$G" --headless --path . --import
```

## Time limits

Headless Godot hangs when a script fails to compile. Wrap every run in a time limit, e.g. `perl -e 'alarm 90; exec @ARGV' "$G" --headless --path . ...`, and treat a killed run as a failure.

`--check-only --script` does not load autoloads, so "Identifier not found" for an autoload there is a false alarm.

## Profiles

Always pass `--profile=<name>` of your own for any test or run. Never use the default profile: it is the user's real library.

Each profile keeps its data apart under `user://profiles/<name>/` (library, settings, installed plugins).

## Plugins folder

`plugins/` is git-ignored, so a fresh worktree has no plugins. The app loads every folder with a `plugin.json` up to two levels down.

Consequence: in a fresh worktree the self-test runs no plugin checks. Site support always lives in plugin repositories, never in this repo.

## Tests

Run the self-test first.

| Script | Needs | Run |
|---|---|---|
| Self-test | Nothing | `perl -e 'alarm 600; exec @ARGV' "$G" --headless --path . -- --profile=selftest --selftest` |
| Sync test | Local WebDAV server (see below) | `GODOT="$G" perl -e 'alarm 600; exec @ARGV' scripts/dev/synctest.sh http://127.0.0.1:8089/` |
| Plugin test | A plugin repository link, network | `perl -e 'alarm 300; exec @ARGV' "$G" --path . -- --profile=plugintest --plugintest=<link to a plugin repository> [--live]` |

Self-test: checks every script compiles, text rules, sentence splitting, TTS pause timing, plugin helpers, and every loaded plugin's own checks. It passes only if the output has a line starting with `SELFTEST PASSED`. CI runs it headless with `--profile=selftest`. Headless runs skip the TTS pacing checks (no voices there); with a window they also run.

Sync test: start a local server first (in the background), then run the script from the repo root. It uses its own `synctest_a` and `synctest_b` profiles and wipes them first.

```sh
pip install wsgidav cheroot && wsgidav --host 127.0.0.1 --port 8089 --root /tmp/dav --auth anonymous
```

Plugin test: installs every plugin the repository lists, checks each one runs from the data folder, and removes them again. With `--live` it also searches each site and opens the first result and its first chapter.

## Running the app

```sh
"$G" --path . -- --profile=<your-name>
```

On Linux, use the official Godot build, not a distro package; see docs/DEVELOPMENT.md.

## Building exports

One script builds every target; see docs/DEVELOPMENT.md "Building": `installer/build.sh` (menu), or name targets, e.g. `installer/build.sh exe`.

## Logs

Settings → About → Troubleshooting → "Keep a log" (off by default) writes one log file per start of the app to `logs/` in the profile's data folder, keeping the last 5.
