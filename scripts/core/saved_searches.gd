extends Node
## Saved searches: a site's search or works list, saved like a bookmark. The app
## never fetches them by itself. On desktop they open in the Web tab, where
## page_seen() compares the works on the page with the ones seen before, and the
## page highlights the new ones. Where there's no Web tab (Android) they open in
## the system browser.
##
## The searches themselves ({id, name, url, added}) are a setting, so Sync carries
## them to other devices. What each device has already seen stays on the device
## (saved_searches.json). The first time a search is opened on a device,
## everything on it counts as seen.

signal changed

const MAX_SEEN := 3000
const FRESH_FOR := 1800.0   # a work found new stays highlighted this long (reloads, paging back)

var _state := {}   # id -> {seen: [book keys], fresh: {key: unix time}, last_opened, last_found}


func _ready() -> void:
	_load()
	Settings.changed.connect(func(key):
		if key == "saved_searches":
			_prune()
			changed.emit())
	# Left over from when the app checked saved searches by itself.
	DirAccess.remove_absolute(Settings.data_dir() + "/saved_searches_checked.txt")


# --- searches ----------------------------------------------------------------

func searches() -> Array:
	return (Settings.get_value("saved_searches") as Array).duplicate(true)


func get_search(id: String) -> Dictionary:
	for s in searches():
		if s.id == id:
			return s
	return {}


func find_by_url(url: String) -> Dictionary:
	var key := normalize(url)
	for s in searches():
		if normalize(s.url) == key:
			return s
	return {}


## Save a search. Returns the search, or {"error": msg}.
func add(url: String, name := "") -> Dictionary:
	url = url.strip_edges().get_slice("#", 0)
	if Plugins.listing_plugin(url) == null:
		return {"error": "That isn't a search or list of works on a site whose plugin supports saved searches. Do a search on such a site and use that page's link."}
	var existing := find_by_url(url)
	if not existing.is_empty():
		return existing
	var s := {"id": "%d%04d" % [Time.get_unix_time_from_system(), randi() % 10000], "name": name if name.strip_edges() != "" else default_name(url),
		"url": HtmlText._re("([?&])page=\\d+&?").sub(url, "$1", true).trim_suffix("&").trim_suffix("?"),
		"added": Time.get_unix_time_from_system()}
	var list := searches()
	list.append(s)
	Settings.set_value("saved_searches", list)
	return s


func update(id: String, fields: Dictionary) -> void:
	var list := searches()
	for s in list:
		if s.id == id:
			s.merge(fields, true)
	Settings.set_value("saved_searches", list)


func remove(id: String) -> void:
	Settings.set_value("saved_searches", searches().filter(func(s): return s.id != id))


## A readable name from the URL ("hero academia", "Works in Overwatch"), from the site's plugin.
static func default_name(url: String) -> String:
	var p := Plugins.listing_plugin(url)
	return p.listing_name(url) if p else "Saved search"


## A hint for a saved search (e.g. sort it by date), from the site's plugin.
static func tip(url: String) -> String:
	var p := Plugins.listing_plugin(url)
	return p.listing_tip(url) if p else ""


static func normalize(url: String) -> String:
	return HtmlText._re("([?&])page=\\d+&?").sub(url.get_slice("#", 0), "$1", true).trim_suffix("&").trim_suffix("?") \
		.replace("https://", "").replace("http://", "").replace("www.", "")


# --- opening ---------------------------------------------------------------

## When the user last opened the search (unix time, 0 if never), on this device.
func last_opened(id: String) -> float:
	return float(_state.get(id, {}).get("last_opened", 0))


## The user opened the search (in the Web tab or the system browser).
func mark_opened(id: String) -> void:
	if get_search(id).is_empty():
		return
	var st: Dictionary = _state.get(id, {})  # no "seen" yet: the first page_seen still only takes note
	st.last_opened = Time.get_unix_time_from_system()
	_state[id] = st
	_save()
	changed.emit()


## A page of a saved search was opened in the Web tab with these works on it
## (their links). Returns the ones that are new: not seen on this search before
## and not in the library. The first time, everything counts as seen.
func page_seen(url: String, works: Array) -> Array:
	var s := find_by_url(url)
	if s.is_empty():
		return []
	var st: Dictionary = _state.get(s.id, {})
	var first := not st.has("seen")
	if first:
		st.seen = []
	var seen := {}
	for k in st.seen:
		seen[k] = true
	var fresh: Dictionary = st.get("fresh", {})  # work key -> when it was first seen
	var now := Time.get_unix_time_from_system()
	var out := []
	var found := 0
	for w in works:
		var key := Library.book_key(str(w))
		if not seen.has(key):
			seen[key] = true
			st.seen.append(key)
			if not first:
				fresh[key] = now
				found += 1
		if fresh.has(key) and now - float(fresh[key]) < FRESH_FOR and Library.find_by_url(str(w)).is_empty():
			out.append(w)
	for k in fresh.keys():
		if now - float(fresh[k]) > 86400.0:
			fresh.erase(k)
	if st.seen.size() > MAX_SEEN:
		st.seen = st.seen.slice(st.seen.size() - MAX_SEEN)
	st.fresh = fresh
	st.last_opened = now
	if found > 0 or not st.has("last_found"):
		st.last_found = found
	_state[s.id] = st
	_save()
	changed.emit()
	return out


## How many new works the last opening found.
func last_found(id: String) -> int:
	return int(_state.get(id, {}).get("last_found", 0))


## Forget the state of searches that were removed (here or on another device).
func _prune() -> void:
	var ids := searches().map(func(s): return s.id)
	for id in _state.keys():
		if not id in ids:
			_state.erase(id)
	_save()


func _path() -> String:
	return Settings.data_dir() + "/saved_searches.json"


func _load() -> void:
	if not FileAccess.file_exists(_path()):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path()))
	if data is Dictionary:
		_state = data
		for id in _state:
			_state[id].erase("new")  # works found by the old background checks


func _save() -> void:
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_state))
