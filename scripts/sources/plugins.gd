extends Node
## Finds, loads, installs and removes site plugins (see PLUGINS.md).
##
## Plugins are loaded from two places:
##   <data folder>/plugins/<id>/   installed: from a link, a plugin repository,
##                                 a folder, or by Sync from another device
##   res://plugins/                for working on plugins: any folder up to two
##                                 levels down with a plugin.json (git-ignored,
##                                 and left out of exported builds)
## When both have the same plugin, the newer version is used.

signal changed
## A plugin's status() changed (e.g. a helper it runs went online).
signal status_changed
## A plugin wants to tell the user something (see SourcePlugin.notify).
signal message(text: String, kind: String)

## The plugin API this app provides. A plugin's "api" must match.
const API := 1
const DEV_DIR := "res://plugins"
const MANIFEST := "plugin.json"

## Every plugin found: {id, name, version, manifest, dir, origin ("installed" | "dev"),
## enabled, error, plugin (SourcePlugin or null)}
var entries: Array = []
## Loaded and enabled plugins, in name order.
var plugins: Array[SourcePlugin] = []

## id -> {v: version, t: unix time, removed: bool}: what was installed or removed
## here and when, so Sync can carry it to other devices.
var records := {}


func _ready() -> void:
	_load_records()
	reload()
	Settings.changed.connect(func(key): if key == "plugins_off": reload())  # also when Sync brings the change


func _exit_tree() -> void:
	shutdown_all()


## Stop every plugin's background work (the app is closing).
func shutdown_all() -> void:
	for p in plugins:
		var t := Time.get_ticks_msec()
		p.shutdown()
		AppLog.info("close", "plugin %s shut down in %d ms" % [p.id, AppLog.since(t)])


func installed_dir() -> String:
	var d := Settings.data_dir() + "/plugins"
	DirAccess.make_dir_recursive_absolute(d)
	return d


# --- loading -----------------------------------------------------------------

## Scan both places again and load what changed. Plugins whose folder and version
## are the same keep running, except `changed_id`, which is always loaded afresh.
func reload(changed_id := "") -> void:
	var running := {}
	for p in plugins:
		running[p.id] = p
	plugins.clear()
	var found := {}  # id -> entry
	for e in _scan(installed_dir(), "installed", 1) + _scan(DEV_DIR, "dev", 2):
		var other: Dictionary = found.get(e.id, {})
		if other.is_empty() or compare_versions(e.version, other.version) > 0 \
				or (compare_versions(e.version, other.version) == 0 and e.origin == "dev"):
			found[e.id] = e
	entries = found.values()
	entries.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	var off: Array = Settings.get_value("plugins_off")
	for e in entries:
		e.enabled = not e.id in off
		if e.error == "":
			e.error = _unsupported(e.manifest)
		if e.error != "" or not e.enabled:
			continue
		var old: SourcePlugin = running.get(e.id)
		if old:
			running.erase(e.id)
			if e.id != changed_id and old.dir == e.dir and old.version == e.version:
				e.plugin = old
				plugins.append(old)
				continue
			old.shutdown()  # replaced: stop it before the new copy starts
		var p := _instantiate(e)
		if p == null:
			continue
		e.plugin = p
		plugins.append(p)
		p.status_changed.connect(func(): status_changed.emit())
		p.setup()
	for id in running:  # removed, switched off or broken now
		running[id].shutdown()
	plugins.sort_custom(func(a, b): return a.name.naturalnocasecmp_to(b.name) < 0)
	Net.set_sites(site_gaps())
	changed.emit()


## {domain: seconds between requests} for every loaded plugin's sites (see Net).
func site_gaps() -> Dictionary:
	var out := {}
	for p in plugins:
		var gap := Net.DEFAULT_GAP
		var v: Variant = p.manifest.get("request_gap")
		if v is float or v is int:
			gap = clampf(float(v), 0.0, 60.0)
		for d in p.manifest.get("domains", []):
			out[str(d).to_lower()] = gap
	return out


func _scan(root: String, origin: String, depth: int) -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(root):
		return out
	for d in DirAccess.get_directories_at(root):
		if d.begins_with("."):
			continue
		var path := root.path_join(d)
		if FileAccess.file_exists(path.path_join(MANIFEST)):
			out.append(_entry(path, origin))
		elif depth > 1:
			out.append_array(_scan(path, origin, depth - 1))
	return out


func _entry(path: String, origin: String) -> Dictionary:
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(path.path_join(MANIFEST)))
	if not (m is Dictionary) or str(m.get("id", "")) == "":
		return {"id": "?" + path, "name": path.get_file(), "version": "", "manifest": {}, "dir": path, "origin": origin,
			"enabled": false, "error": "plugin.json is missing or damaged.", "plugin": null}
	return {"id": str(m.id), "name": str(m.get("name", m.id)), "version": str(m.get("version", "0")), "manifest": m,
		"dir": path, "origin": origin, "enabled": true, "error": "", "plugin": null}


## Why a plugin can't run here, or "".
func _unsupported(m: Dictionary) -> String:
	var api := int(m.get("api", 0))
	if api > API:
		return "Needs a newer version of the app (plugin API %d, this app has %d)." % [api, API]
	if api < API:
		return "Made for an older version of the app (plugin API %d, this app has %d)." % [api, API]
	if "process" in m.get("needs", []) and not (OS.has_feature("pc") and not OS.has_feature("web")):
		return "Only works on desktop."
	return ""


func _instantiate(e: Dictionary) -> SourcePlugin:
	var file: String = e.manifest.get("main", "source.gd")
	var path: String = e.dir.path_join(file)
	if not FileAccess.file_exists(path) and not ResourceLoader.exists(path):
		e.error = "%s is missing." % file
		return null
	# Installed plugins can change on disk, so don't reuse a cached copy of the script.
	var mode := ResourceLoader.CACHE_MODE_IGNORE if e.origin == "installed" else ResourceLoader.CACHE_MODE_REUSE
	var script: Variant = ResourceLoader.load(path, "", mode)
	if not (script is GDScript) or not script.can_instantiate():
		e.error = "%s has errors and couldn't be loaded." % file
		return null
	var p: Variant = script.new()
	if not (p is SourcePlugin):
		e.error = "%s doesn't extend SourcePlugin." % file
		return null
	p.id = e.id
	p.name = e.name
	p.version = e.version
	p.manifest = e.manifest
	p.dir = e.dir
	return p


# --- lookups -----------------------------------------------------------------

func get_plugin(id: String) -> SourcePlugin:
	for p in plugins:
		if p.id == id:
			return p
	return null


func get_entry(id: String) -> Dictionary:
	for e in entries:
		if e.id == id:
			return e
	return {}


## The plugin for a link's site, or null.
func for_url(url: String) -> SourcePlugin:
	for p in plugins:
		if p.handles_url(url):
			return p
	return null


func display_name(id: String) -> String:
	var e := get_entry(id)
	return e.name if not e.is_empty() else ""


func book_key(url: String) -> String:
	var p := for_url(url)
	return p.book_key(url) if p else ""


func chapter_key(url: String) -> String:
	var p := for_url(url)
	return p.chapter_key(url) if p else ""


## The plugin that can watch this page as a saved search, or null.
func listing_plugin(url: String) -> SourcePlugin:
	var p := for_url(url)
	return p if p and p.is_listing_url(url) else null


## Plugins with a start page for the Web tab's site menu.
func with_home() -> Array[SourcePlugin]:
	var out: Array[SourcePlugin] = []
	for p in plugins:
		if p.home_url() != "":
			out.append(p)
	return out


func set_enabled(id: String, on: bool) -> void:
	var off: Array = (Settings.get_value("plugins_off") as Array).duplicate()
	off.erase(id)
	if not on:
		off.append(id)
	Settings.set_value("plugins_off", off)  # reloads (see _ready)


## Runs every plugin's own checks (for the self-test).
func run_tests(check: Callable) -> void:
	for p in plugins:
		p.run_tests(func(n, got, want): check.call("[%s] %s" % [p.id, n], got, want))


# --- installing --------------------------------------------------------------

## Install or update a plugin from a link to its plugin.json (or a folder or
## GitHub repository that has one). -> {id, name, version} or {error}
func install_from_url(url: String) -> Dictionary:
	var found := await resolve(url)
	if found.has("error"):
		return found
	if found.has("plugins"):
		return {"error": "That link is a plugin repository. Add it under Plugin repositories instead."}
	return await _install_manifest(found.manifest, found.base)


## What a link points to: {manifest, base} for a plugin, {name, plugins, base} for a repository, or {error}.
func resolve(url: String) -> Dictionary:
	url = github_raw(url.strip_edges())
	if not url.begins_with("http"):
		return {"error": "Please paste a full link starting with http(s)://"}
	var tries: Array = [url] if url.ends_with(".json") else [url.trim_suffix("/") + "/index.json", url.trim_suffix("/") + "/" + MANIFEST]
	var last := ""
	for u in tries:
		var r: Dictionary = await Net.get_json(u, 20.0, false)
		if not (r.ok and r.data is Dictionary):
			last = r.error if r.error != "" else "not a JSON file"
			continue
		var base: String = u.get_base_dir() + "/"
		if r.data.get("plugins") is Array:
			# The index only lists folders; each plugin's own plugin.json says what it is.
			var list := []
			for p in r.data.plugins:
				var path := str(p.get("path", "") if p is Dictionary else p).trim_suffix("/")
				var murl := base + (path + "/" if path != "" else "") + MANIFEST
				var m: Dictionary = await Net.get_json(murl, 20.0, false)
				if m.ok and m.data is Dictionary and str(m.data.get("id", "")) != "":
					list.append({"id": str(m.data.id), "name": str(m.data.get("name", m.data.id)), "version": str(m.data.get("version", "0")),
						"description": str(m.data.get("description", "")), "manifest_url": murl, "error": _unsupported(m.data)})
			return {"name": str(r.data.get("name", url)), "plugins": list, "base": base}
		if r.data.has("id") and r.data.has("api"):
			return {"manifest": r.data, "base": base}
		last = "it isn't a plugin.json or plugin repository index"
	return {"error": "Couldn't read a plugin at that link (%s)." % last}


## https://github.com/<owner>/<repo>[/tree/<branch>/<path>] -> the raw files' address.
static func github_raw(url: String) -> String:
	var m := HtmlText._re("^https?://github\\.com/([^/]+)/([^/#?]+?)(?:\\.git)?(?:/(?:tree|blob)/([^/]+)(/.*)?)?/?$").search(url)
	if m == null:
		return url
	return "https://raw.githubusercontent.com/%s/%s/%s%s" % [m.get_string(1), m.get_string(2),
		m.get_string(3) if m.get_string(3) != "" else "HEAD", m.get_string(4).trim_suffix("/")]


func _install_manifest(m: Dictionary, base: String) -> Dictionary:
	var err := check_manifest(m)
	if err != "":
		return {"error": err}
	var files := {}
	for f in m.get("files", [MANIFEST]):
		var r: Dictionary = await Net.request(base + str(f), [], 30.0, HTTPClient.METHOD_GET, "", false)
		if not r.ok:
			return {"error": "Couldn't download %s (%s)." % [f, r.error]}
		files[str(f)] = r.body
	files[MANIFEST] = JSON.stringify(m, "\t").to_utf8_buffer()
	return install_files(m, files)


## Install from a folder on this computer (desktop).
func install_from_folder(path: String) -> Dictionary:
	var mf := path.path_join(MANIFEST)
	if not FileAccess.file_exists(mf):
		return {"error": "There's no plugin.json in that folder."}
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(mf))
	if not (m is Dictionary):
		return {"error": "plugin.json in that folder is damaged."}
	var err := check_manifest(m)
	if err != "":
		return {"error": err}
	var files := {}
	for f in m.get("files", [MANIFEST]):
		if not FileAccess.file_exists(path.path_join(str(f))):
			return {"error": "%s is listed in plugin.json but missing from the folder." % f}
		files[str(f)] = FileAccess.get_file_as_bytes(path.path_join(str(f)))
	files[MANIFEST] = FileAccess.get_file_as_bytes(mf)
	return install_files(m, files)


## Why a plugin can't be installed or run here, or "".
func check_manifest(m: Dictionary) -> String:
	var err := _check_files(m)
	return err if err != "" else _unsupported(m)


## The id and file names are safe to write to disk.
func _check_files(m: Dictionary) -> String:
	var id := str(m.get("id", ""))
	if not HtmlText._re("^[a-z0-9][a-z0-9_-]{0,40}$").search(id):
		return "The plugin's id is missing or invalid."
	if not (m.get("files", []) is Array):
		return "The plugin's file list is invalid."
	for f in m.get("files", []):
		var s := str(f)
		if s == "" or s.begins_with("/") or ".." in s or ":" in s or "\\" in s:
			return "The plugin lists an unsafe file name (%s)." % s
	return ""


## Write a plugin's files ({relative path: bytes}) and load it. -> {id, name, version} or {error}
func install_files(m: Dictionary, files: Dictionary, stamp := -1.0) -> Dictionary:
	var unsafe := _check_files(m)
	if unsafe != "":
		return {"error": unsafe}
	var id := str(m.id)
	var target := installed_dir().path_join(id)
	var tmp := target + ".new"
	_remove_tree(tmp)
	for f in files:
		var path := tmp.path_join(f)
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var fa := FileAccess.open(path, FileAccess.WRITE)
		if fa == null:
			_remove_tree(tmp)
			return {"error": "Couldn't write %s (%s)." % [f, error_string(FileAccess.get_open_error())]}
		fa.store_buffer(files[f])
		fa.close()
	_keep_local_files(target, tmp)
	_remove_tree(target)
	DirAccess.rename_absolute(tmp, target)
	records[id] = {"v": str(m.get("version", "0")), "t": stamp if stamp >= 0 else Time.get_unix_time_from_system(), "removed": false}
	_save_records()
	reload(id)
	var e := get_entry(id)
	if e.get("error", "") != "":
		return {"error": "Installed, but it can't run: " + e.error}
	return {"id": id, "name": e.get("name", id), "version": e.get("version", "")}


## Keep files a plugin made for itself (e.g. a Python environment) across updates.
func _keep_local_files(old: String, new: String) -> void:
	if not DirAccess.dir_exists_absolute(old):
		return
	for keep in (get_entry(old.get_file()).get("manifest", {}) as Dictionary).get("keep", []):
		var from := old.path_join(str(keep))
		if (DirAccess.dir_exists_absolute(from) or FileAccess.file_exists(from)) and not ".." in str(keep):
			DirAccess.make_dir_recursive_absolute(new.path_join(str(keep)).get_base_dir())
			DirAccess.rename_absolute(from, new.path_join(str(keep)))


## Remove an installed plugin. Plugins in res://plugins (for development) can't be removed here.
func remove(id: String, stamp := -1.0) -> void:
	var p := get_plugin(id)
	if p:
		p.shutdown()
	_remove_tree(installed_dir().path_join(id))
	records[id] = {"v": str(records.get(id, {}).get("v", "")), "t": stamp if stamp >= 0 else Time.get_unix_time_from_system(), "removed": true}
	_save_records()
	reload(id)


func is_installed(id: String) -> bool:
	return DirAccess.dir_exists_absolute(installed_dir().path_join(id))


# --- repositories -------------------------------------------------------------

func repos() -> Array:
	return (Settings.get_value("plugin_repos") as Array).duplicate()


func add_repo(url: String) -> Dictionary:
	var r := await resolve(url)
	if r.has("error"):
		return r
	if not r.has("plugins"):
		return {"error": "That link is a single plugin, not a repository. Install it with Install from link."}
	var list := repos()
	if not url.strip_edges() in list:
		list.append(url.strip_edges())
		Settings.set_value("plugin_repos", list)
	return r


func remove_repo(url: String) -> void:
	var list := repos()
	list.erase(url)
	Settings.set_value("plugin_repos", list)


## Install or update a plugin listed in a repository.
func install_listed(item: Dictionary) -> Dictionary:
	return await install_from_url(item.manifest_url)


# --- for Sync -----------------------------------------------------------------

## Files of a plugin as {relative path: absolute path}, or {} when they can't all be read
## (sync only carries plugins whose files are all there).
func files_of(id: String) -> Dictionary:
	var e := get_entry(id)
	if e.is_empty() or not (e.manifest.get("files") is Array):
		return {}
	var out := {}
	for f in e.manifest.get("files", []) + [MANIFEST]:
		var path: String = e.dir.path_join(str(f))
		if not FileAccess.file_exists(path):
			return {}
		out[str(f)] = path
	return out


## What this device has: id -> {v, t, removed}. Plugins found in res://plugins count as installed.
func sync_records() -> Dictionary:
	var out := records.duplicate(true)
	for e in entries:
		if e.manifest.is_empty():
			continue
		var r: Dictionary = out.get(e.id, {})
		if r.is_empty() or (not r.get("removed", false) and r.get("v", "") != e.version):
			out[e.id] = {"v": e.version, "t": maxf(float(r.get("t", 0)), _mtime(e)), "removed": false}
	return out


func _mtime(e: Dictionary) -> float:
	return float(FileAccess.get_modified_time(e.dir.path_join(MANIFEST)))


# --- helpers -----------------------------------------------------------------

## -1, 0 or 1 comparing dotted versions ("1.10.0" > "1.9").
static func compare_versions(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := pa[i].to_int() if i < pa.size() else 0
		var y := pb[i].to_int() if i < pb.size() else 0
		if x != y:
			return 1 if x > y else -1
	return 0


func _records_path() -> String:
	return installed_dir().path_join("installed.json")


func _load_records() -> void:
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(_records_path())) if FileAccess.file_exists(_records_path()) else null
	records = data if data is Dictionary else {}


func _save_records() -> void:
	var f := FileAccess.open(_records_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(records, "\t"))


static func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	DirAccess.remove_absolute(path)
