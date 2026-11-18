# Notes for AI agents

- **Setup, tests and running:** follow `.claude/skills/bibliotheca-run/SKILL.md` (a Claude Code skill; other agents
  can read it as plain instructions). In short: a fresh checkout needs one headless Godot import first
  (`--headless --path . --import`); wrap every Godot run in a time limit (headless Godot hangs when a script fails
  to compile) and treat a killed run as a failure; run the self-test first; and give every run a profile of your own
  (`-- --profile=<name>`), never the user's default data.
- **No site code in the core:** support for a site always goes into a plugin repository (see PLUGINS.md), never into
  this repo.
- **Version:** don't change the version in pull requests. After each merge that changes the app, a workflow raises
  the patch number on `main` (see "Versions" in docs/DEVELOPMENT.md). Only a minor or major release sets it by hand.
- **PR titles:** conventional commit titles in plain language, e.g.
  `fix(linux): reading aloud no longer stops at 2x speed with RHVoice`.
- **Never name sites:** this repo is public. Never name a supported website (name, domain, URL, branding), or any
  plugin repository, in commits, PR titles or bodies, code comments, docs or screenshots. Describe them generically
  ("a site", "the plugin repo").
- **Comments:** write only what the code can't say: why a choice was made, gotchas, the quirk that forced a
  workaround (a TTS engine that caps its speed, a site's odd markup, described without naming the site). No
  restating the code, no issue numbers or history, no step-by-step stories of how something was verified.
- **PR body:** the problem in a sentence or two, then how you fixed it. End with the model and harness that did the
  work.
- **PR evidence:** UI changes need before/after images; motion or timing (e.g. reading-aloud highlighting) needs a
  short video. Upload them to the PR on GitHub; never commit PR-only screenshots or assets. Screenshots must not show
  a site's name, URL or branding, or copyrighted book text from a site; use a book of your own or public-domain text.
- **PR scope:** one request is one PR. Split it only when the maintainer asks.
