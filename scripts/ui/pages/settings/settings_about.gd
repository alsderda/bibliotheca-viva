class_name SettingsAbout
extends SettingsSection
## The About tab of Settings: version, credits, troubleshooting and the log export.


## Third-party parts the reader itself uses (plugins list their own).
const CREDITS := [
	{"name": "Godot Engine", "what": "Game engine the app is built on", "url": "https://godotengine.org",
		"license": "MIT", "license_url": "https://godotengine.org/license"},
	{"name": "Godot's bundled libraries", "what": "FreeType, HarfBuzz, ICU and others shipped inside Godot", "url": "https://github.com/godotengine/godot",
		"license": "Various", "license_url": "https://github.com/godotengine/godot/blob/master/COPYRIGHT.txt"},
	{"name": "godot-wry", "what": "Built-in browser (system web view)", "url": "https://github.com/doceazedo/godot_wry",
		"license": "MIT", "license_url": "https://github.com/doceazedo/godot_wry/blob/main/LICENSE"},
	{"name": "Inter", "what": "Interface font", "url": "https://github.com/rsms/inter",
		"license": "SIL OFL 1.1", "license_url": "https://github.com/rsms/inter/blob/master/LICENSE.txt"},
	{"name": "Literata", "what": "Reading font", "url": "https://github.com/googlefonts/literata",
		"license": "SIL OFL 1.1", "license_url": "https://github.com/googlefonts/literata/blob/main/OFL.txt"},
	{"name": "Lucide", "what": "Style the icons are drawn in", "url": "https://lucide.dev",
		"license": "ISC", "license_url": "https://lucide.dev/license"},
]


var _log_dialog: FileDialog


func build() -> void:
	_section("Bibliothéca-viva %s" % ProjectSettings.get_setting("application/config/version", "?"), [
		UI.label("Build %s" % ProjectSettings.get_setting("application/config/version_code", "?"), "Small"),
		UI.label("An ebook reader with text-to-speech, library sync over WebDAV, and a plugin system for fetching books from web serial sites. Built with Godot %s." % Engine.get_version_info().string, "Muted", true),
		_row("Source code", "Code, issues and releases on GitHub.", _external_link("GitHub", "https://github.com/alsderda/bibliotheca-viva", "")),
		_row("Data folder", ProjectSettings.globalize_path(Settings.data_dir()), UI.button("Open", "external", "", func(): OS.shell_open(ProjectSettings.globalize_path(Settings.data_dir())))),
	])
	_troubleshooting()
	var rows: Array = [UI.label("Third-party software and assets the reader uses. Sites come from plugins, which carry their own licenses.", "Muted", true)]
	for c in CREDITS:
		var links := UI.hbox(8, [
			_external_link(c.license, c.license_url),
			_external_link("Website", c.url),
		])
		rows.append(_row(c.name, c.what, links))
	_section("Credits", rows)


func _troubleshooting() -> void:
	var on := CheckButton.new()
	on.button_pressed = AppLog.is_on()
	on.focus_mode = Control.FOCUS_NONE
	on.toggled.connect(func(v): Settings.set_value("logging", v); page.rebuild_keep_scroll())
	var count := AppLog.files().size()
	var kept := "No logs kept." if count == 0 else "%d %s kept, %s." % [count, "log" if count == 1 else "logs", String.humanize_size(AppLog.total_bytes())]
	var actions := _chip_row()
	if AppLog.can_share():  # Android: send or save the file; the clipboard is too small for long logs
		actions.add_child(UI.button("Share…", "share", "", func():
			if not AppLog.share():
				page.main.toast("Couldn't share the logs", "error")))
	actions.add_child(UI.button("Export…", "download", "", _export_log))
	if not AppLog.can_share():
		actions.add_child(UI.button("Copy", "copy", "", func():
			DisplayServer.clipboard_set(AppLog.export_text())
			page.main.toast("Logs copied to the clipboard", "ok")))
	if OS.has_feature("pc"):
		actions.add_child(UI.button("Open folder", "external", "", func(): OS.shell_open(ProjectSettings.globalize_path(AppLog.folder()))))
	actions.add_child(UI.button("Delete", "trash", "GhostButton", func():
		AppLog.clear()
		page.main.toast("Old logs deleted", "ok")
		page.rebuild_keep_scroll()))
	for b in actions.get_children():
		(b as Button).disabled = count == 0
	_section("Troubleshooting", [
		_row("Keep a log", "Writes what the app does, with the time, to a file on this device: errors, closing, sync and downloads. Nothing is sent anywhere. Each start makes a new log, and the last %d are kept." % AppLog.KEEP_FILES, on),
		UI.label(kept + (" Share or export them" if AppLog.can_share() else " Export or copy them") + " to attach to a bug report.", "Small", true),
		actions,
	])


func _export_log() -> void:
	if _log_dialog == null:
		_log_dialog = FileDialog.new()
		_log_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_log_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_log_dialog.use_native_dialog = true
		_log_dialog.filters = PackedStringArray(["*.txt ; Text files"])
		_log_dialog.file_selected.connect(func(path):
			var ok := AppLog.export_to(path)
			page.main.toast("Logs saved to " + path.get_file() if ok else "Couldn't save the logs there", "ok" if ok else "error"))
		page.add_child(_log_dialog)
	_log_dialog.current_file = AppLog.export_name()
	_log_dialog.popup_centered_ratio(0.6)


## A link button that always opens in the system browser, never the built-in one.
## Ghost style by default; pass "" for a normal button.
func _external_link(text: String, url: String, variation := "GhostButton") -> Button:
	var b := UI.button(text, "external", variation, func(): OS.shell_open(url))
	b.tooltip_text = url
	return b
