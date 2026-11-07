# Development

How to run, build and test Bibliothéca-viva from source, and where its code lives. For what the app does, see the [README](../README.md). To write a plugin, see [PLUGINS.md](../PLUGINS.md).

## Run

```sh
godot --path .            # or open project.godot in the Godot editor
```

To work on plugins, clone their repositories into `plugins/` (git-ignored). The app loads every folder with a `plugin.json` up to two levels down, so a single plugin and a repository of several both work. Exported builds leave `plugins/` out.

The library, settings and installed plugins live in the user data folder, `bibliotheca-viva` (set by `config/custom_user_dir_name` in `project.godot`): `%APPDATA%\bibliotheca-viva` on Windows, `~/Library/Application Support/bibliotheca-viva` on macOS, `~/.local/share/bibliotheca-viva` (or `$XDG_DATA_HOME`) on Linux, and the app's private storage on Android. Settings → About shows the exact path.

### Logs

Settings → About → Troubleshooting → "Keep a log" (off by default, per device, also in release builds) writes a log file per start of the app to `logs/` in the profile's data folder, keeping the last 5. It holds everything Godot prints (errors and warnings too, with GDScript backtraces when available), each line stamped with the time since start, plus steps the app notes with `AppLog.info(area, text)`: closing (how long each part took), sync runs, web and WebDAV requests (without query strings or passwords) and page changes. The same section exports or copies all kept logs as one text file, with the app version and device at the top. `scripts/core/app_log.gd` has the code; `AppLog.info` does nothing while logging is off, so it's cheap to call.

### Building

One script builds every target. Run it without arguments and pick from the menu, or name the targets:

```sh
installer/build.sh                # menu: APK (debug), APK (release), Windows EXE, Windows installer, macOS, AppImage
installer/build.sh exe            # export/windows/bibliotheca-viva.exe, plus the licenses
installer/build.sh installer      # export/bibliotheca-viva-Setup-<version>.exe (Windows only)
installer/build.sh mac            # export/bibliotheca-viva-<version>-macos.zip, the .app (on a Mac)
installer/build.sh dmg            # export/bibliotheca-viva-<version>.dmg (on a Mac)
installer/build.sh appimage       # export/bibliotheca-viva-<version>-x86_64.AppImage
installer/build.sh apk            # export/android/bibliotheca-viva-<version>-debug.apk
installer/build.sh apk --install  # same, then installs it on the connected phone (adb)
installer/build.sh exe apk        # several at once
```

It's a bash script; on Windows, run it from Git Bash. You need Godot 4.7 with the export templates for your targets (Editor → Manage Export Templates). Godot doesn't add itself to `PATH`, so the script looks at `GODOT`, `PATH` and `/Applications/Godot.app`, and otherwise asks you to paste the path to the Godot executable (on Windows, the `*_console.exe`, so Godot's output shows in the terminal). It saves the pasted path in `installer/godot_path.local` (git-ignored) and uses it next time. The version in the file names comes from `config/version` in `project.godot`.

### Versions

Versions follow Android's scheme: a version name people read and a version code that only goes up.

- **Version name** (`major.minor.patch`, e.g. `0.0.1`): `config/version` in `project.godot`. Every PR raises the patch number by 1, unless there's a reason not to (a PR that only touches docs, or a bigger release that raises minor or major and resets the numbers after it).
- **Version code** (e.g. `10`): `config/version_code` in `project.godot` and `version/code` in the Android preset in `export_presets.cfg`. Both must be the same; `installer/build.sh` stops if they aren't. Every PR raises it by 10, unless there's a reason not to. The steps of 10 leave room for an extra build between two PRs, such as a hotfix.

A GitHub check (`.github/workflows/version-check.yml`) enforces this: a PR that changes anything in `scripts/`, `scenes/`, `addons/`, `assets/`, `installer/`, `project.godot` or `export_presets.cfg` fails unless the version name and code both go up and the two codes match. A ruleset on `main` makes the check required, and only the repo admin can merge past it ("Merge without waiting for requirements") when there's a reason to skip the bump.

The Android build and the Windows file properties pick up the version name from `project.godot` (their own fields in the presets are left empty). Settings → About shows both.

The app looks at this repo's GitHub releases (pre-releases included) at most once every four hours (`scripts/core/update_check.gd`). If one has a higher version than `config/version`, a notice above Settings in the sidebar opens its release page. So tag each release `v<config/version>` of the build it ships.

### App icon

`assets/icon.svg` is the app icon (the same book logo as the sidebar). Godot uses it for the window and the editor; the exports need fixed-size files, which live in `assets/icons/`: `icon.ico` for the Windows exe, its window and the installer, PNGs for the Android launcher (192 px icon, plus 432 px adaptive foreground and background layers drawn from `icon_foreground.svg` and `icon_background.svg`), `icon_1024.png` for the macOS app (Godot turns it into an `.icns`) and `icon_256.png` for the AppImage. After changing any of the SVGs, run `Godot --headless --path . --script installer/make_icons.gd` to render them again (errors about autoloads in its output are harmless).

### Windows installer

`installer/build.sh installer` exports the app (preset "Windows Desktop" in `export_presets.cfg`), adds the licenses, and writes `export/bibliotheca-viva-Setup-<version>.exe`, a single-file installer. It asks for a folder (by default `%LOCALAPPDATA%\Programs\Bibliothéca-viva`, or the folder of an existing install), whether to add a desktop shortcut and whether to delete the installer afterwards (checked by default), unpacks the app there and overwrites older files, so you update by running a newer installer. Library and settings live in the user data folder (`%APPDATA%\bibliotheca-viva`), so updating doesn't touch them. Everything is per user, so no admin rights are needed.

Besides the files, Setup adds a Start menu shortcut and an entry in Windows' list of installed apps (Settings → Apps, under `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\bibliotheca-viva`) with the version from `config/version`. It also puts `uninstall.exe` next to the app, plus `uninstall.files`, the list of files it unpacked. The uninstaller deletes only those files (and the WebView2 cache next to the exe), the shortcuts and the registry entry, then the folder if it's empty, so installing into a folder that holds other things is safe. It asks whether to delete the library and settings too.

Command line: `Setup.exe "/dir=C:\some\folder" [/desktop] [/deletesetup]` installs without any window; `/deletesetup` deletes Setup.exe when it is done. `uninstall.exe /silent` uninstalls without any window and keeps the library; add `/purge` to delete it as well.

The installer is compiled from `installer/Setup.cs`, twice: first without the app as `uninstall.exe`, then with the app and `uninstall.exe` embedded as Setup. On Windows the script uses the C# compiler that comes with Windows, so nothing else is needed. On macOS or Linux it uses Mono's `mcs` instead (`brew install mono`), which builds the same .NET Framework 4.5 program. Building the EXE on a Mac needs Godot's Windows export templates.

### macOS

`installer/build.sh mac` exports the "macOS" preset in `export_presets.cfg` (bundle id `com.alsderda.bibliotheca-viva`, universal for Apple Silicon and Intel) to `export/macos/Bibliothéca-viva.app` and zips it as `export/bibliotheca-viva-<version>-macos.zip` (with `ditto`, which keeps the bundle's signature intact). `installer/build.sh dmg` puts the app, a link to Applications and the licenses on `export/bibliotheca-viva-<version>.dmg`. Both only work on a Mac: Godot makes `.app` bundles only there, and the DMG needs `hdiutil`. You need Godot's macOS export templates.

The app is signed ad-hoc (free, no Apple account), not with a Developer ID, so it isn't notarized: macOS refuses to open it the first time, and you allow it once in System Settings → Privacy & Security → Open Anyway. The script signs the app itself with `codesign`, and Godot's signing is off in the preset. The reason: Godot names the program and its `.pck` after the project, and macOS can't verify a signature over file names with an "é" in them, so the script renames both to `bibliotheca-viva` first (the program finds the `.pck` by its own name). The web view framework keeps its own signature from godot-wry. Library and settings live in `~/Library/Application Support/bibliotheca-viva`.

### Linux AppImage

`installer/build.sh appimage` exports the "Linux" preset (x86_64; godot-wry has no ARM Linux build) and packs it with `libgodot_wry.so`, a `.desktop` file, the icon and the licenses into `export/bibliotheca-viva-<version>-x86_64.AppImage`. An AppImage is the AppImage runtime (a small Linux program, downloaded once to `export/appimage-runtime-x86_64` from [AppImage/type2-runtime](https://github.com/AppImage/type2-runtime)) followed by a squashfs image of the app folder, so the script only needs `mksquashfs` (`squashfs-tools` on Linux, `brew install squashfs` on macOS) and works on a Mac too. You need Godot's Linux export templates.

The AppImage doesn't bundle the system libraries the app uses: the Web tab needs WebKitGTK (`libwebkit2gtk-4.1`), and reading aloud needs speech-dispatcher with a voice (e.g. espeak-ng). Without WebKitGTK the rest of the app still works and the Web tab says it isn't available. Library and settings live in `~/.local/share/bibliotheca-viva`.

### Android

`installer/build.sh apk` uses the "Android" preset in `export_presets.cfg` (package `com.alsderda.bibliotheca_viva`, arm64, Android 7+). You need Godot 4.7 with the export templates, JDK 17 and the Android SDK (platform-tools and build-tools). On macOS:

```sh
brew install openjdk@17 && brew install --cask android-commandlinetools
sdkmanager --sdk_root=$HOME/Library/Android/sdk "platform-tools" "build-tools;36.1.0"
```

The script finds the JDK and SDK in the usual places (or `JAVA_HOME`, `ANDROID_HOME`) and fills in Godot's Editor Settings → Export → Android paths if they're empty. Debug builds are signed with the standard Android debug key (`~/.android/debug.keystore`, created if missing), which is fine for sideloading: copy the APK to the phone and open it, or use `--install` with USB debugging on.

The export is a Gradle build so that `addons/android_speech` and `addons/android_keystore` can add to it:

- a `<queries>` entry for `TTS_SERVICE`. Without it, Android 11+ hides third-party TTS engines (RHVoice, eSpeak, …) from the app and silently falls back to Google TTS.
- a small Java plugin (`addons/android_speech/java`, copied into the build at export) that plays the speech itself from a foreground service. Godot's main loop stops while the app is in the background, so `scripts/core/speech.gd` hands the plugin everything it should read, with the pauses, in advance.
- another Java plugin (`addons/android_keystore/java`) that encrypts the sync password with an AES key kept in the Android Keystore, for `scripts/core/keyring.gd`.

The script installs Godot's Android build template into `android/` (git-ignored) on the first run and again when Godot's version changes. The first build downloads Gradle and its dependencies, so it needs internet and takes a few minutes.

Release builds (from 0.2.0 on) are signed with the release keystore `bibliotheca-viva-release.keystore` (alias `bibliotheca-viva`). It lives outside the repo, in `~/.android/` on each machine that builds releases. Every release must be signed with this same key, because Android only installs an update signed with the key the installed app has.

```sh
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH=~/.android/bibliotheca-viva-release.keystore
export GODOT_ANDROID_KEYSTORE_RELEASE_USER=bibliotheca-viva
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD='...'  # single quotes, so symbols in it aren't changed by the shell
installer/build.sh apk --release  # export/android/bibliotheca-viva-<version>.apk
```

The key was created once with:

```sh
keytool -genkeypair -keystore ~/.android/bibliotheca-viva-release.keystore -storetype PKCS12 -alias bibliotheca-viva -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=bibliotheca-viva"
```

Its certificate's SHA-256 fingerprint is `26:29:3F:68:EB:16:00:51:9F:F2:37:50:75:4F:19:82:04:DF:A3:30:9D:95:71:0B:AD:7B:0F:5E:C6:9E:5C:14`. `apksigner verify --print-certs <apk>` (in the SDK's build-tools) shows it for a built APK.

Raise `version/code` in the preset for every release you install over an older one. The version name comes from `config/version`.

### Sync test

```sh
pip install wsgidav cheroot && wsgidav --host 127.0.0.1 --port 8089 --root /tmp/dav --auth anonymous
GODOT=godot scripts/dev/synctest.sh http://127.0.0.1:8089/
```

Runs two profiles as two devices against the server: first sync, changes on each side, a removal, a plugin installed, updated and removed, a sync with nothing to do (counting its requests), both syncing at the same time, an upload of a big book killed part way (it goes up as packs, and the other device fetches it in few requests), a couple of chapters added later (sent one by one), and a change made just before closing.

### Self-test

```sh
godot --path . -- --profile=selftest --selftest   # every script compiles, text rules, sentence splitting, TTS pause timing, plugin helpers, and every loaded plugin's own checks
```

A GitHub check (`.github/workflows/tests.yml`) runs it headless on Linux for every PR and push to `main`. There's no TTS there, so the pacing checks are skipped, and `plugins/` isn't in the repo, so no plugin checks run.

### Plugin test

```sh
godot --path . -- --profile=plugintest --plugintest=<link to a plugin repository> [--live]
```

Installs every plugin the repository lists, checks each one runs from the data folder, and removes them again. With `--live` it also searches each site and opens the first result and its first chapter.

## Layout of the code

| Path | What |
| --- | --- |
| `scripts/core/` | Settings, Library, SavedSearches (storage in `user://profiles/<name>/`), TextRules, Net (HTTP), Speech (TTS), EPUB/TXT/HTML parsing, Sync and its WebDAV client (`webdav.gd`, raw TCP/TLS because Godot's HTTPClient can't send PROPFIND/MKCOL) |
| `scripts/sources/` | `Plugins` (finds, loads, installs and removes plugins), `SourcePlugin` (the base class plugins extend, with HTML helpers), `Sources` (routes searches, new books and chapter downloads to plugins) |
| `scripts/ui/` | Theme, icons (SVG rendered at runtime), app shell (`main.gd`), pages, widgets |
| `scripts/sources/web_extract.gd` | JavaScript injected into Web-tab pages (finds chapter text and next/prev links on any page, runs plugins' site recognisers, highlights the paragraph being read) |
| `addons/godot_wry/` | godot-wry 1.0.2 (MIT): system web view GDExtension for Windows, macOS, Linux |
| `plugins/` | Plugins you're working on (git-ignored; see [PLUGINS.md](../PLUGINS.md)) |
