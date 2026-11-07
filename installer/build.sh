#!/usr/bin/env bash
# Builds Bibliothéca-viva for one or more targets. Run it without arguments to pick
# the targets from a menu, or name them:
#
#   installer/build.sh                      # menu
#   installer/build.sh apk                  # export/android/bibliotheca-viva-<version>-debug.apk
#   installer/build.sh apk --release        # export/android/bibliotheca-viva-<version>.apk (needs a release keystore)
#   installer/build.sh apk --install        # also install the APK on the connected device with adb
#   installer/build.sh exe                  # export/windows/bibliotheca-viva.exe (+ licenses)
#   installer/build.sh installer            # export/bibliotheca-viva-Setup-<version>.exe
#   installer/build.sh exe apk              # several at once
#
# Needs Godot 4.7 with export templates. Godot doesn't add itself to PATH, so if
# it isn't found (GODOT, PATH, the usual install folders) the script asks for the
# path and saves it in installer/godot_path.local. On Windows, use the
# *_console.exe so Godot's output shows up in the terminal.
#
# The installer target compiles installer/Setup.cs: on Windows (Git Bash) with
# the C# compiler that comes with Windows, elsewhere with Mono's mcs
# (brew install mono). The APK target also needs a
# JDK 17 and the Android SDK; JAVA_HOME and ANDROID_HOME override the usual
# locations. See docs/DEVELOPMENT.md.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
saved_path_file="installer/godot_path.local"

die() { echo "Error: $*" >&2; exit 1; }

case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) os=windows ;;
	Darwin) os=mac ;;
	*) os=linux ;;
esac

# A path Windows programs (Godot, csc) understand.
native_path() { if [ "$os" = windows ]; then cygpath -m "$1"; else echo "$1"; fi; }

# --- options ---------------------------------------------------------------------
targets=()
apk_mode=debug
install=0
for arg in "$@"; do
	case "$arg" in
		apk | exe | installer) targets+=("$arg") ;;
		--release) apk_mode=release ;;
		--install) install=1 ;;
		-h | --help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option: $arg (try --help)" ;;
	esac
done

if [ ${#targets[@]} -eq 0 ]; then
	echo "What do you want to build?"
	echo "  1) Android APK (debug, for sideloading)"
	echo "  2) Android APK (release)"
	echo "  3) Windows EXE"
	echo "  4) Windows installer"
	read -r -p "Numbers, separated by spaces (e.g. 1 3): " choice
	for n in $choice; do
		case "$n" in
			1) targets+=(apk) ;;
			2) targets+=(apk); apk_mode=release ;;
			3) targets+=(exe) ;;
			4) targets+=(installer) ;;
			*) die "no option $n" ;;
		esac
	done
	[ ${#targets[@]} -eq 0 ] && die "nothing selected"
	if [[ " ${targets[*]} " == *" apk "* ]]; then
		read -r -p "Install the APK on the connected device with adb? [y/N] " answer
		[[ "$answer" =~ ^[Yy] ]] && install=1
	fi
fi
want() { [[ " ${targets[*]} " == *" $1 "* ]]; }

if want installer && [ "$os" != windows ] && ! command -v mcs >/dev/null; then
	die "building the Windows installer outside Windows needs Mono's mcs (brew install mono)"
fi

# --- find Godot ------------------------------------------------------------------
# Turns what the user typed or saved into a runnable Godot path, or prints nothing.
resolve_godot() {
	local p="$1"
	p="${p#"${p%%[![:space:]]*}"}"  # trim
	p="${p%"${p##*[![:space:]]}"}"
	p="${p#[\"\']}"  # quotes from "Copy as path"
	p="${p%[\"\']}"
	[ -z "$p" ] && return 0
	[ "$os" = windows ] && p="$(cygpath -u "$p")"
	[ -d "$p" ] && [ -x "$p/Contents/MacOS/Godot" ] && p="$p/Contents/MacOS/Godot"  # Godot.app
	if [ -f "$p" ] && "$p" --version >/dev/null 2>&1; then echo "$p"; fi
}

find_godot() {
	local c
	for c in "${GODOT:-}" "$(cat "$saved_path_file" 2>/dev/null || true)" \
		"$(command -v godot || true)" "$(command -v godot4 || true)" \
		/Applications/Godot.app/Contents/MacOS/Godot; do
		c="$(resolve_godot "$c")"
		[ -n "$c" ] && { echo "$c"; return; }
	done
	return 0
}

godot="$(find_godot)"
while [ -z "$godot" ]; do
	echo
	echo "Godot not found. Godot doesn't add itself to PATH, so paste the path to the Godot executable."
	case "$os" in
		windows) echo "Use the console version, e.g. F:\\godot\\Godot_v4.7.2-stable_win64_console.exe" ;;
		mac) echo "e.g. /Applications/Godot.app" ;;
		*) echo "e.g. ~/bin/Godot_v4.7.2-stable_linux.x86_64" ;;
	esac
	read -r -p "Godot path: " entered || die "no Godot path given"
	entered="${entered/#\~/$HOME}"
	godot="$(resolve_godot "$entered")"
	if [ -n "$godot" ]; then
		echo "$godot" > "$saved_path_file"
		echo "Saved to $saved_path_file"
	else
		echo "That isn't a Godot executable that runs: $entered"
	fi
done
godot_version="$("$godot" --version | head -1 | tr -d '\r' | sed -E 's/\.[^.]+\.[0-9a-f]+$//')"
echo "Godot: $godot ($godot_version)"

version="$(sed -n 's/^config\/version="\(.*\)"/\1/p' project.godot | tr -d '\r')"
[ -z "$version" ] && version=dev
# The Android version code lives in two places: project.godot (so the app can show it)
# and the Android preset (which Godot reads when exporting). They must match.
version_code="$(sed -n 's/^config\/version_code=\([0-9]*\)/\1/p' project.godot | tr -d '\r')"
preset_code="$(sed -n 's/^version\/code=\([0-9]*\)/\1/p' export_presets.cfg | tr -d '\r')"
[ "$version_code" = "$preset_code" ] || die "version code mismatch: project.godot has config/version_code=$version_code, export_presets.cfg has version/code=$preset_code"
echo "Version: $version (code $version_code)"

# Godot's own folders: editor settings and export templates.
case "$os" in
	windows) godot_dirs=("$(cygpath -u "$APPDATA")/Godot") ;;
	mac) godot_dirs=("$HOME/Library/Application Support/Godot") ;;
	*) godot_dirs=("${XDG_CONFIG_HOME:-$HOME/.config}/godot" "${XDG_DATA_HOME:-$HOME/.local/share}/godot") ;;
esac

export_preset() {  # mode, preset, output file
	"$godot" --headless --path "$(native_path "$root")" "--export-$1" "$2" "$(native_path "$root/$3")" || true
	[ -f "$3" ] || die "Godot export of \"$2\" failed (see output above)"
}

zip_dir() {  # folder, zip file
	rm -f "$2"
	if command -v zip >/dev/null; then
		(cd "$1" && zip -qr "$root/$2" .)
	else
		powershell.exe -NoProfile -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem;" \
			"[IO.Compression.ZipFile]::CreateFromDirectory('$(cygpath -w "$1")', '$(cygpath -w "$root/$2")', 'Optimal', \$false)"
	fi
}

unzip_to() {  # zip file, folder
	if command -v unzip >/dev/null; then
		unzip -q "$1" -d "$2"
	else
		powershell.exe -NoProfile -Command "Expand-Archive -LiteralPath '$(cygpath -w "$1")' -DestinationPath '$(cygpath -w "$2")'"
	fi
}

# The first run in a fresh checkout has to import the assets before exporting.
echo "Importing project..."
"$godot" --headless --path "$(native_path "$root")" --import >/dev/null 2>&1 || true

built=()

# --- Windows EXE -----------------------------------------------------------------
build_exe() {
	local stage=export/windows
	echo
	echo "== Windows EXE"
	rm -rf "$stage"
	mkdir -p "$stage/licenses"
	export_preset release "Windows Desktop" "$stage/bibliotheca-viva.exe"
	cp LICENSE "$stage/licenses/bibliotheca-viva-LICENSE.txt"
	cp assets/fonts/OFL-*.txt "$stage/licenses/"
	cp addons/godot_wry/LICENSE "$stage/licenses/godot_wry-LICENSE.txt"
	built+=("$stage/bibliotheca-viva.exe")
}

# --- Windows installer -----------------------------------------------------------
# Compiles installer/Setup.cs into $1. The other arguments are files to embed, each as
# "path,name". Without an embedded payload.zip, the program runs as the uninstaller.
compile_setup() {
	local out="$1" res resources=() sources=(installer/Setup.cs export/BuildInfo.cs) src
	shift
	if [ "$os" = windows ]; then
		local windir; windir="$(cygpath -u "${WINDIR:-C:\\Windows}")"
		local csc="$windir/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
		[ -f "$csc" ] || csc="$windir/Microsoft.NET/Framework/v4.0.30319/csc.exe"
		[ -f "$csc" ] || die "C# compiler (csc.exe) not found. It ships with .NET Framework 4."
		local fw; fw="$(cygpath -w "$(dirname "$csc")")"
		for res in "$@"; do resources+=("-resource:$(cygpath -w "${res%,*}"),${res##*,}"); done
		local win_sources=()
		for src in "${sources[@]}"; do win_sources+=("$(cygpath -w "$src")"); done
		"$csc" -nologo -target:winexe -optimize+ "-win32icon:$(cygpath -w assets/icons/icon.ico)" "-out:$(cygpath -w "$out")" \
			${resources[@]+"${resources[@]}"} \
			"-reference:$fw\\System.IO.Compression.dll" "-reference:$fw\\System.IO.Compression.FileSystem.dll" \
			-reference:System.Windows.Forms.dll "${win_sources[@]}" || die "compiling $out failed"
	else
		# Mono builds the same .NET Framework 4.5 program as Windows' csc.
		for res in "$@"; do resources+=("-resource:$res"); done
		mcs -nologo -target:winexe -optimize+ -sdk:4.5 -win32icon:assets/icons/icon.ico "-out:$out" \
			${resources[@]+"${resources[@]}"} -reference:System.IO.Compression.dll -reference:System.IO.Compression.FileSystem.dll \
			-reference:System.Windows.Forms.dll -reference:System.Drawing.dll "${sources[@]}" || die "compiling $out failed"
	fi
}

build_installer() {
	want exe || build_exe
	echo
	echo "== Windows installer"
	local zip=export/payload.zip uninstaller=export/uninstall.exe setup="export/bibliotheca-viva-Setup-$version.exe"
	zip_dir export/windows "$zip"
	rm -f "$setup" "$uninstaller"
	# The version shown in Windows' list of installed apps.
	printf 'static class BuildInfo { public const string Version = "%s"; }\n' "$version" > export/BuildInfo.cs
	compile_setup "$uninstaller"
	compile_setup "$setup" "$zip,payload.zip" "$uninstaller,uninstall.exe"
	rm -f "$zip" "$uninstaller" export/BuildInfo.cs
	built+=("$setup")
}

# --- Android APK -----------------------------------------------------------------
build_apk() {
	echo
	echo "== Android APK ($apk_mode)"
	local jdk
	if [ -z "${JAVA_HOME:-}" ]; then
		for jdk in /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home /usr/lib/jvm/java-17-openjdk-amd64; do
			[ -d "$jdk" ] && export JAVA_HOME="$jdk" && break
		done
		[ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ] && JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)" && export JAVA_HOME
	fi
	[ -z "${JAVA_HOME:-}" ] && die "JDK 17 not found. Set JAVA_HOME."
	if [ -z "${ANDROID_HOME:-}" ]; then
		case "$os" in
			windows) ANDROID_HOME="$(cygpath -u "$LOCALAPPDATA")/Android/Sdk" ;;
			mac) ANDROID_HOME="$HOME/Library/Android/sdk" ;;
			*) ANDROID_HOME="$HOME/Android/Sdk" ;;
		esac
		export ANDROID_HOME
	fi
	[ -d "$ANDROID_HOME" ] || die "Android SDK not found. Set ANDROID_HOME."
	local java_home_u android_home_u
	java_home_u="$( [ "$os" = windows ] && cygpath -u "$JAVA_HOME" || echo "$JAVA_HOME")"
	android_home_u="$( [ "$os" = windows ] && cygpath -u "$ANDROID_HOME" || echo "$ANDROID_HOME")"

	# Godot reads the JDK and SDK paths only from its editor settings. Fill them in
	# when they're empty (same as Editor Settings → Export → Android).
	local dir settings="" pair key value
	for dir in "${godot_dirs[@]}"; do
		settings="$(ls "$dir"/editor_settings-4*.tres 2>/dev/null | tail -1 || true)"
		[ -n "$settings" ] && break
	done
	if [ -n "$settings" ]; then
		for pair in "java_sdk_path=$(native_path "$java_home_u")" "android_sdk_path=$(native_path "$android_home_u")"; do
			key="export/android/${pair%%=*}" value="${pair#*=}"
			if ! grep -q "^$key = \"..*\"" "$settings"; then
				grep -v "^$key = " "$settings" > "$settings.tmp" && echo "$key = \"$value\"" >> "$settings.tmp"
				mv "$settings.tmp" "$settings"
				echo "Set $key in $(basename "$settings")"
			fi
		done
	fi

	if [ "$apk_mode" = debug ]; then
		# Standard Android debug key, created once and shared with other projects.
		local keystore="${GODOT_ANDROID_KEYSTORE_DEBUG_PATH:-$HOME/.android/debug.keystore}"
		if [ ! -f "$keystore" ]; then
			mkdir -p "$(dirname "$keystore")"
			"$java_home_u/bin/keytool" -genkeypair -v -keystore "$(native_path "$keystore")" -storepass android -keypass android \
				-alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000
		fi
		export GODOT_ANDROID_KEYSTORE_DEBUG_PATH="$(native_path "$keystore")"
		export GODOT_ANDROID_KEYSTORE_DEBUG_USER="${GODOT_ANDROID_KEYSTORE_DEBUG_USER:-androiddebugkey}"
		export GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD="${GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD:-android}"
	else
		local v
		for v in GODOT_ANDROID_KEYSTORE_RELEASE_PATH GODOT_ANDROID_KEYSTORE_RELEASE_USER GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD; do
			[ -z "${!v:-}" ] && die "release builds need $v (see docs/DEVELOPMENT.md, Android)"
		done
	fi

	# The preset uses a Gradle build (so addons can add manifest entries), which needs
	# Godot's Android build template in android/. Install it like Editor → Project →
	# Install Android Build Template does, and again whenever Godot's version changes.
	local source_zip=""
	for dir in "${godot_dirs[@]}"; do
		source_zip="$dir/export_templates/$godot_version/android_source.zip"
		[ -f "$source_zip" ] && break
	done
	[ -f "$source_zip" ] || die "Android export templates for Godot $godot_version not found (Editor → Manage Export Templates)."
	if [ "$(tr -d '\r' < android/.build_version 2>/dev/null || true)" != "$godot_version" ]; then
		echo "Installing the Android build template for Godot $godot_version"
		rm -rf android
		mkdir -p android/build
		unzip_to "$source_zip" android/build
		touch android/build/.gdignore
		echo "$godot_version" > android/.build_version
	fi

	local suffix="" out
	[ "$apk_mode" = debug ] && suffix="-debug"
	out="export/android/bibliotheca-viva-$version$suffix.apk"
	mkdir -p export/android
	rm -f "$out"
	export_preset "$apk_mode" "Android" "$out"
	built+=("$out")

	if [ "$install" = 1 ]; then
		"$android_home_u/platform-tools/adb" install -r "$(native_path "$root/$out")"
	fi
}

want exe && build_exe
want installer && build_installer
want apk && build_apk

echo
echo "Done:"
for f in "${built[@]}"; do
	echo "  $f ($(( $(wc -c < "$f") / 1048576 )) MB)"
done
