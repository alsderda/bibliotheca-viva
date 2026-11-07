extends Node
## Persistent user settings. Emits `changed(key)` whenever a value is set.

signal changed(key: String)

const DEFAULTS := {
	"reader_theme": "dark",        # dark | sepia | light
	"reader_font": "serif",        # serif | sans
	"font_size": 20,
	"line_spacing": 6,
	"paragraph_gap": 18,            # px between paragraphs
	"column_width": 720,            # maximum width of the text, px
	"side_margin": 24,              # minimum space left and right of the text, px
	"text_align": "left",           # left | justify | center
	"first_line_indent": false,     # indent the first line of each paragraph
	"tts_voice": "",
	"tts_rate": 1.0,
	"tts_pitch": 1.0,
	"tts_volume": 80,
	"tts_auto_advance": true,
	"tts_follow": true,
	"tts_mode": "paragraph",        # paragraph | sentence
	"tts_pause_sentence": 150,      # ms between sentences (sentence mode)
	"tts_pause_paragraph": 350,     # ms between paragraphs
	"tts_pause_heading": 900,       # ms after a heading or chapter title
	"tts_pause_chapter": 1500,      # ms before continuing to the next chapter
	"tts_read_headings": true,
	"tts_skip_symbols": true,       # skip lines with no letters or digits (e.g. "* * *")
	"tts_max_chars": 1200,          # longer paragraphs are split into sentences
	"tts_highlight": "background",  # background | underline | color | none
	"tts_preview_text": "This is how chapters will sound when read aloud.",
	"library_view": "grid",
	"web_home": "https://duckduckgo.com/",
	"web_last_url": "",
	"web_auto_next": true,          # continue to the next chapter page when listening
	"web_save_as_you_go": true,     # store chapters you open in the Web tab in the library
	"saved_searches": [],           # see SavedSearches
	"site_rules": [],               # see SiteRules
	"http_revalidate": true,        # ask sites whether a kept page changed, and reuse it if not (see Net)
	"http_keep_waits": true,        # a wait a site asked for (Retry-After) still holds after a restart (see Net)
	"plugins_off": [],              # ids of plugins switched off
	"plugin_repos": [],             # plugin repository links (see Plugins)
	"plugin_settings": {},          # plugin id -> its own settings (see SourcePlugin.get_setting)
	"logging": false,               # keep a log file to help find problems (see AppLog)
}

## Settings that only make sense on one device, so Sync leaves them alone.
## (Voice ids differ between operating systems; a log is for the device with the problem.)
const LOCAL_ONLY := ["tts_voice", "web_last_url", "plugin_settings", "logging"]

const READER_THEMES := {
	"dark": {"bg": Color("#121418"), "text": Color("#d8dbe0"), "muted": Color("#8a919c"), "highlight": Color(0.35, 0.55, 1.0, 0.18)},
	"sepia": {"bg": Color("#f3ead8"), "text": Color("#4a3b2c"), "muted": Color("#8c7a63"), "highlight": Color(0.80, 0.55, 0.20, 0.22)},
	"light": {"bg": Color("#fbfaf7"), "text": Color("#1f2329"), "muted": Color("#6b7280"), "highlight": Color(0.20, 0.45, 0.95, 0.14)},
}

var profile := "default"
var _values := {}
## key -> unix time of the last change, so Sync knows which device changed it last.
var stamps := {}


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--profile="):
			profile = arg.get_slice("=", 1)
	_values = DEFAULTS.duplicate(true)
	_load()


func data_dir() -> String:
	var dir := "user://profiles/%s" % profile
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func get_value(key: String) -> Variant:
	return _values.get(key, DEFAULTS.get(key))


func set_value(key: String, value: Variant) -> void:
	if _values.get(key) == value:
		return
	_values[key] = value
	stamps[key] = Time.get_unix_time_from_system()
	_save()
	changed.emit(key)


## Used by Sync: set a value changed on another device, keeping its timestamp.
func apply_synced(key: String, value: Variant, stamp: float) -> void:
	if not DEFAULTS.has(key) or key in LOCAL_ONLY:
		return
	stamps[key] = stamp
	if _values.get(key) == value:
		_save()
		return
	_values[key] = value
	_save()
	changed.emit(key)


func reader_colors() -> Dictionary:
	return READER_THEMES.get(get_value("reader_theme"), READER_THEMES.dark)


func _path() -> String:
	return data_dir() + "/settings.json"


func _load() -> void:
	if not FileAccess.file_exists(_path()):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path()))
	if parsed is Dictionary:
		for k in parsed:
			if DEFAULTS.has(k):
				_values[k] = parsed[k]
		if parsed.get("_stamps") is Dictionary:
			stamps = parsed._stamps
		else:  # settings saved before sync existed: date changed values by the file
			var t := FileAccess.get_modified_time(_path())
			for k in parsed:
				if DEFAULTS.has(k) and parsed[k] != DEFAULTS[k]:
					stamps[k] = t


func _save() -> void:
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f:
		var data := _values.duplicate()
		data._stamps = stamps
		f.store_string(JSON.stringify(data, "\t"))
