extends Node
## Optional log file for finding problems, switched on in Settings → About
## ("logging", off by default, per device). While it is on, everything the app
## and Godot print (including errors and warnings) goes into a file with the
## time, plus the steps the app notes with `AppLog.info()`. Each start of the
## app writes its own file; the last KEEP_FILES are kept. Works in release
## builds too.

const DIR := "logs"
const KEEP_FILES := 5
const MAX_BYTES := 8 * 1024 * 1024  # per file; later lines are dropped
const SHARE_PLUGIN := "BibliothecaVivaShare"  # addons/android_share
const SHARE_DIR := "user://share"  # the file handed to the share menu (inside the app's storage)

var _sink: _Sink
var _started := false  # true once start-up is over (later logs are switched on by hand)


func _enter_tree() -> void:
	_apply()
	_started = true
	Settings.changed.connect(func(key): if key == "logging": _apply())


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			info("app", "close requested")
		NOTIFICATION_APPLICATION_PAUSED:
			info("app", "paused")
		NOTIFICATION_APPLICATION_RESUMED:
			info("app", "resumed")
		NOTIFICATION_EXIT_TREE:
			info("app", "leaving the scene tree")
		NOTIFICATION_PREDELETE:
			info("app", "last step the app can log; Godot shuts down after this")
			_stop()


func is_on() -> bool:
	return _sink != null


## Writes one line, e.g. info("sync", "done in 420 ms"). Does nothing while logging is off.
func info(area: String, text: String) -> void:
	var s := _sink  # may be called from another thread
	if s:
		s.write("[%s] %s" % [area, text])


## Milliseconds since `start` (a Time.get_ticks_msec() value), for "took N ms" lines.
static func since(start: int) -> int:
	return Time.get_ticks_msec() - start


func folder() -> String:
	var d := Settings.data_dir().path_join(DIR)
	DirAccess.make_dir_recursive_absolute(d)
	return d


## Log files, oldest first.
func files() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(folder()):
		if f.get_extension() == "log":
			out.append(folder().path_join(f))
	out.sort()  # names start with the date and time
	return out


func total_bytes() -> int:
	var n := 0
	for f in files():
		var fa := FileAccess.open(f, FileAccess.READ)
		if fa:
			n += fa.get_length()
	return n


## All kept logs in one text, oldest first, after a short description of the device.
func export_text() -> String:
	var parts := PackedStringArray([_about_device(), ""])
	for f in files():
		parts.append("===== %s =====" % f.get_file())
		parts.append(FileAccess.get_file_as_string(f))
	return "\n".join(parts)


func export_to(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(export_text())
	return f.get_error() == OK


## True where share() works (Android, with the share plugin in the build).
static func can_share() -> bool:
	return Engine.has_singleton(SHARE_PLUGIN)


## Opens Android's share menu with all kept logs as one text file. -> false if it can't.
func share() -> bool:
	if not can_share():
		return false
	DirAccess.make_dir_recursive_absolute(SHARE_DIR)
	for old in DirAccess.get_files_at(SHARE_DIR):  # earlier exports, already handed over
		DirAccess.remove_absolute(SHARE_DIR.path_join(old))
	var path := SHARE_DIR.path_join(export_name())
	if not export_to(path):
		return false
	return bool(Engine.get_singleton(SHARE_PLUGIN).share(ProjectSettings.globalize_path(path), "text/plain", "Bibliothéca-viva logs"))


## File name for an export, e.g. bibliotheca-viva-log-2026-11-07.txt.
static func export_name() -> String:
	return "bibliotheca-viva-log-%s.txt" % Time.get_date_string_from_system()


## Deletes every log file except the one being written.
func clear() -> void:
	var current := _sink.path if _sink else ""
	for f in files():
		if f != current:
			DirAccess.remove_absolute(f)


func _apply() -> void:
	var want := bool(Settings.get_value("logging"))
	if want and _sink == null:
		_start()
	elif not want and _sink:
		info("log", "logging switched off")
		_stop()


func _start() -> void:
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var sink := _Sink.new(folder().path_join("session_%s.log" % stamp))
	if not sink.ok():
		return
	_sink = sink
	OS.add_logger(_sink)
	_prune()
	_sink.write("[log] " + _about_device().replace("\n", "\n    "))
	_sink.write("[log] logging switched on" if _started else "[log] times are since the app started")


func _stop() -> void:
	if _sink:
		OS.remove_logger(_sink)
		_sink.close()
		_sink = null


func _prune() -> void:
	var all := files()
	for i in maxi(all.size() - KEEP_FILES, 0):
		DirAccess.remove_absolute(all[i])


func _about_device() -> String:
	var lines := PackedStringArray([
		"Bibliothéca-viva %s (build %s), Godot %s" % [ProjectSettings.get_setting("application/config/version", "?"),
			ProjectSettings.get_setting("application/config/version_code", "?"), Engine.get_version_info().string],
		"%s %s%s, %s" % [OS.get_name(), OS.get_version(), (" (%s)" % OS.get_distribution_name()) if OS.get_name() == "Linux" else "", OS.get_model_name()],
		"%s, %d threads, %s, %s" % [OS.get_processor_name(), OS.get_processor_count(), RenderingServer.get_video_adapter_name(), DisplayServer.get_name()],
		"%s build, locale %s, profile %s" % ["debug" if OS.is_debug_build() else "release", OS.get_locale(), Settings.profile],
	])
	return "\n".join(lines)


## Receives everything Godot prints. Godot may call it from any thread, so
## writes are guarded; it must never print itself.
class _Sink extends Logger:
	var path := ""
	var _file: FileAccess
	var _mutex := Mutex.new()
	var _main_thread := OS.get_main_thread_id()
	var _full := false

	func _init(p: String) -> void:
		path = p
		_file = FileAccess.open(p, FileAccess.WRITE)

	func ok() -> bool:
		return _file != null

	func close() -> void:
		_mutex.lock()
		_file = null
		_mutex.unlock()

	func write(text: String) -> void:
		var t := Time.get_ticks_msec()
		var head := "%s +%d.%03d" % [Time.get_time_string_from_system(), t / 1000, t % 1000]
		if OS.get_thread_caller_id() != _main_thread:
			head += " (thread %d)" % OS.get_thread_caller_id()
		_mutex.lock()
		if _file and not _full:
			if _file.get_length() > MAX_BYTES:
				_full = true
				_file.store_line("%s [log] file is full, the rest of this session isn't logged" % head)
			else:
				_file.store_line("%s %s" % [head, text.strip_edges(false, true)])
			_file.flush()  # keep every line if the app is killed or hangs
		_mutex.unlock()

	func _log_message(message: String, error: bool) -> void:
		write(("[stderr] " if error else "") + message)

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		var kind: String = ["ERROR", "WARNING", "SCRIPT ERROR", "SHADER ERROR"][clampi(error_type, 0, 3)]
		var text := "%s: %s\n    at %s (%s:%d)" % [kind, rationale if rationale != "" else code, function, file, line]
		for bt in script_backtraces:
			if not bt.is_empty():
				text += "\n" + bt.format(4)
		write(text)
