extends Node
## Looks on GitHub for a release newer than this build, at most once every four hours.
## It only tells: the sidebar shows a notice that opens the release page. Pre-releases count.

signal changed

const RELEASES_URL := "https://api.github.com/repos/alsderda/bibliotheca-viva/releases?per_page=20"
const INTERVAL := 4 * 3600   # seconds between checks, also across restarts
const FILE := "update_check.json"

## Newest release found, or "" when this build is up to date (or nothing is known yet).
var latest := ""
var latest_url := ""
var _checked_at := 0.0
var _busy := false


func _ready() -> void:
	_load()
	_update_latest(latest, latest_url)  # a saved find is dropped if this build is as new by now
	for arg in OS.get_cmdline_user_args():
		if arg in ["--selftest", "--plugintest", "--synctest"]:
			return  # tests stay off the network
	var t := Timer.new()
	t.wait_time = 15 * 60  # cheap: check() returns at once until the four hours are up
	t.timeout.connect(check)
	add_child(t)
	t.start()
	check.call_deferred()


func current() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0"))


func check() -> void:
	if _busy or Time.get_unix_time_from_system() - _checked_at < INTERVAL:
		return
	_busy = true
	var r: Dictionary = await Net.get_json(RELEASES_URL, 20.0, false)
	_busy = false
	if not r.ok or not r.data is Array:
		return  # offline or GitHub said no: try again on the next tick
	_checked_at = Time.get_unix_time_from_system()
	var best := ""
	var best_url := ""
	for rel in r.data:
		if not rel is Dictionary or rel.get("draft", false):
			continue
		var tag := str(rel.get("tag_name", ""))
		if best == "" or newer(tag, best):
			best = tag
			best_url = str(rel.get("html_url", ""))
	_update_latest(best, best_url)
	_save()


func _update_latest(tag: String, url: String) -> void:
	var v := tag if tag != "" and newer(tag, current()) else ""
	var u := url if v != "" else ""
	if v == latest and u == latest_url:
		return
	latest = v
	latest_url = u
	changed.emit()


## True if version `a` is higher than `b` ("v0.3.0" > "0.2.6"; a leading "v" and any
## "-beta" style suffix are ignored).
static func newer(a: String, b: String) -> bool:
	var pa := _parts(a)
	var pb := _parts(b)
	for i in maxi(pa.size(), pb.size()):
		var x: int = pa[i] if i < pa.size() else 0
		var y: int = pb[i] if i < pb.size() else 0
		if x != y:
			return x > y
	return false


static func _parts(v: String) -> Array[int]:
	var out: Array[int] = []
	for p in v.strip_edges().trim_prefix("v").trim_prefix("V").get_slice("-", 0).split("."):
		out.append(p.to_int())
	return out


func _path() -> String:
	return Settings.data_dir() + "/" + FILE


func _load() -> void:
	if not FileAccess.file_exists(_path()):
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path()))
	if d is Dictionary:
		_checked_at = float(d.get("checked_at", 0.0))
		latest = str(d.get("latest", ""))
		latest_url = str(d.get("url", ""))


func _save() -> void:
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"checked_at": _checked_at, "latest": latest, "url": latest_url}, "\t"))
