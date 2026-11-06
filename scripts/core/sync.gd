extends Node
## Keeps the library, reading positions, text rules and settings the same on all
## your devices, through a folder on a WebDAV server (Nextcloud, Koofr, ...).
##
## Layout inside <server address>/bibliotheca-viva/:
##   devices/<device id>/       one per device; only that device ever writes in it
##     index.json               settings, text rules, plugins, removed books, and per
##                              book: reading position, timestamps, and the md5 of
##                              its file below, so others fetch only changed books
##     books/<hash>.json        a book's details, chapter list and bookmarks
##   books/<hash of book key>/  one folder per book
##     <chapter id>.json        chapter text; written once, never changed
##     cover-<md5>.png          cover image; named by its content, never changed
##   plugins/<id>/<version>/    an installed plugin's files; written once
##
## No file is written by two devices, so one device can't overwrite another's
## changes, and the server's folder listing is the only index (nothing to drift).
## Each sync step can be repeated safely, so an interrupted sync is finished by
## the next one. Each device reads the other devices' files and merges them into
## its library:
##   - book details: the most recently changed version wins
##   - reading position: the most recently read version wins
##   - chapter lists: combined, so chapters saved on either device are kept
##     (an imported book's list only grows at the end: the longest one wins)
##   - removed books: remembered with a timestamp (tombstone); a book is removed
##     everywhere unless some device used it after it was removed
##   - text rules: the most recently changed rule list wins
##   - settings: the most recently changed value wins, per setting
##     (except Settings.LOCAL_ONLY)
##   - plugins: the most recent install, update or removal wins, per plugin.
##     Plugins are brought up to date before books are merged, so every device
##     identifies books and chapters the same way. A plugin that can't run on
##     this device (by its plugin.json) or can't be downloaded is skipped.

signal status_changed

const FOLDER := "bibliotheca-viva/"
const DEBOUNCE := 20.0       # seconds after a local change before syncing
const PERIOD := 600.0        # seconds between background syncs
const GC_AFTER := 30 * 86400 # keep a removed book's files this long on the server
const CLOSE_WAIT := 10.0     # longest the app waits for a final sync on close
const PACE := 0.1            # shortest gap between two requests on one connection
const PARALLEL := 4          # connections used for a book's chapters (Koofr takes ~0.3 s per request)

var running := false
var last_error := ""
var last_sync := 0.0
var progress_text := ""
var _progress_base := ""     # progress_text without a note about waiting for the server
var _progress_shown := 0     # ticks when chapter progress was last shown
var devices: Array = []      # [{id, name, platform, updated}] other devices on the server

var _state := {}             # enabled, url, user, device_id, device_name, last_sync, uploaded_md5, uploaded_books
var _password := ""
## Kept in sync_cache.json; the other devices' book files are kept in sync_devices/.
##   devices: device id -> {book key: md5 of its book file as cached}
##   texts: book id -> {sig, cover}: the state of its chapters and cover when
##     they were last found to be on both sides (see _texts_sig)
var _cache := {"devices": {}, "texts": {}}
var _indexes := {}           # device id -> {etag, data}: other devices' index.json
var _remote_books := {}      # device id -> {book key: data}: their book files, loaded
var _md5s := {}              # book id -> [revision, cover, md5] of this device's book file
var _done := {}              # book id -> {chapter file name: true} known to be on both sides
var _cover_names := {}       # book id -> remote cover file name
var _dirty := false
var _again := false
var _applying := false
var _closing := false
var _debounce: Timer
var _periodic: Timer


func _ready() -> void:
	_load_state()
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.timeout.connect(sync_now)
	add_child(_debounce)
	_periodic = Timer.new()
	_periodic.wait_time = PERIOD
	_periodic.timeout.connect(func(): if is_enabled(): sync_now())
	add_child(_periodic)
	Library.saved.connect(_on_local_change)
	Library.chapter_saved.connect(func(_id, _i): _on_local_change())
	TextRules.changed.connect(_on_local_change)
	Settings.changed.connect(func(key): if not key in Settings.LOCAL_ONLY: _on_local_change())
	_apply_enabled()
	if is_enabled():
		await get_tree().create_timer(2.0).timeout
		sync_now()


func _notification(what: int) -> void:
	if not is_enabled():
		return
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			_finish_and_quit()
		NOTIFICATION_APPLICATION_PAUSED:
			if _dirty:  # Android may stop the app any time after this
				sync_now()
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN:
			if Time.get_unix_time_from_system() - last_sync > 60:
				request_sync(1.0)


# --- setup -------------------------------------------------------------------

func is_enabled() -> bool:
	return _state.get("enabled", false) and is_configured()


func is_configured() -> bool:
	return _state.get("url", "") != ""


func server_url() -> String:
	return _state.get("url", "")


func user_name() -> String:
	return _state.get("user", "")


func has_password() -> bool:
	return _password != ""


func device_id() -> String:
	return _state.device_id


func device_name() -> String:
	return _state.get("device_name", "")


func set_device_name(name: String) -> void:
	_state.device_name = name.strip_edges() if name.strip_edges() != "" else _default_device_name()
	_state.uploaded_md5 = ""
	_save_state()
	_on_local_change()


## Empty password keeps the saved one.
func configure(url: String, user: String, password: String) -> void:
	url = url.strip_edges()
	if url != "" and not url.ends_with("/"):
		url += "/"
	if url != _state.get("url", "") or user != _state.get("user", ""):
		_cache = {"devices": {}, "texts": {}}
		_indexes.clear()
		_remote_books.clear()
		_remove_tree(_remote_dir())
		_done.clear()
		_state.uploaded_md5 = ""
		_state.uploaded_books = {}
	_state.url = url
	_state.user = user.strip_edges()
	if password != "":
		_password = password
		_save_password()
	_save_state()
	status_changed.emit()


func set_enabled(on: bool) -> void:
	_state.enabled = on
	_save_state()
	_apply_enabled()
	status_changed.emit()
	if is_enabled():
		sync_now()


## -> "" when the server answers and the login works, else a message.
func test_connection() -> String:
	if not is_configured():
		return "Enter the server address first."
	var r := await WebDav.new(server_url(), user_name(), _password).list("")
	return "" if r.ok else r.error


## Syncs after `delay` seconds, unless something else asks sooner.
func request_sync(delay := DEBOUNCE) -> void:
	if is_enabled() and (_debounce.is_stopped() or _debounce.time_left > delay):
		_debounce.start(delay)


## Runs a full sync. Returns "" or an error message (also kept in last_error).
## `manual` syncs once even when automatic sync is off.
func sync_now(manual := false) -> String:
	if not is_configured():
		return "Enter the server address first."
	if not manual and not is_enabled():
		return "Sync is off."
	if running:
		_again = true
		while running:
			await get_tree().process_frame
		return last_error
	running = true
	_dirty = false
	_debounce.stop()
	_set_progress("Syncing…")
	var err := await _run()
	running = false
	last_error = err
	if err == "":
		last_sync = Time.get_unix_time_from_system()
		_state.last_sync = last_sync
	else:
		_dirty = true  # try again with the next change or background sync
	_save_state()
	_save_cache()
	_set_progress("")
	if _again:
		_again = false
		request_sync(1.0)
	return err


func _apply_enabled() -> void:
	get_tree().set_auto_accept_quit(not is_enabled())
	if is_enabled():
		_periodic.start()
	else:
		_periodic.stop()
		_debounce.stop()


func _on_local_change() -> void:
	if _applying or not is_enabled():
		return
	_dirty = true
	request_sync()


func _finish_and_quit() -> void:
	if _closing:
		return
	_closing = true
	if _dirty or running:
		get_tree().create_timer(CLOSE_WAIT).timeout.connect(get_tree().quit)
		await sync_now()
	get_tree().quit()


func _set_progress(text: String) -> void:
	progress_text = text
	_progress_base = text
	status_changed.emit()


# --- the sync ----------------------------------------------------------------

func _run() -> String:
	var pool: Array[WebDav] = []
	for n in PARALLEL:
		var d := WebDav.new(server_url(), user_name(), _password)
		d.min_interval = PACE
		d.on_busy_wait = func(seconds: float):
			progress_text = "%s (server busy, waiting %d s)" % [_progress_base, ceili(seconds)]
			status_changed.emit()
		pool.append(d)
	var dav := pool[0]
	var err := await _run_with(dav, pool)
	for d in pool:
		d.close()
	return err


func _run_with(dav: WebDav, pool: Array[WebDav]) -> String:
	var err := await _ensure_folders(dav)
	if err != "":
		return err

	_set_progress("Checking other devices…")
	var listing := await dav.list(FOLDER + "devices/")
	if not listing.ok:
		return listing.error
	var remote := []
	var seen := {}
	for e in listing.entries:
		if not e.is_dir or e["name"] == device_id():
			continue  # devices/<id>.json files are from older versions, which this one can't read
		var r := await _fetch_device(dav, pool, e["name"])
		if r.has("error"):
			return r.error
		if r.has("doc"):
			seen[e["name"]] = true
			remote.append(r.doc)
	for id in _cache.devices.keys():
		if not seen.has(id):
			_forget_device(id)
	devices = remote.map(func(d): return d.get("device", {}).merged({"updated": d.get("updated", 0)}))

	_set_progress("Syncing plugins…")
	err = await _sync_plugins(dav, remote)
	if err != "":
		return err

	_applying = true
	var covers := _merge(remote)
	_applying = false

	var books_listing := await dav.list(FOLDER + "books/")
	if not books_listing.ok:
		return books_listing.error
	var folders := {}
	for e in books_listing.entries:
		if e.is_dir:
			folders[e["name"]] = true
	var texts := _remote_texts(remote)
	var all := Library.books.duplicate()
	var known := {}
	for i in all.size():
		var b: Dictionary = all[i]
		if Library.get_book(b.id).is_empty():
			continue
		known[b.id] = true
		var key := Library.sync_key(b)
		var wanted: Dictionary = covers.get(key, {})
		var sig := _texts_sig(b, folders.has(_folder_name(key)), wanted, texts.get(key, ""))
		var last: Dictionary = _cache.texts.get(b.id, {})
		if last.get("sig", "") == sig:
			if last.get("cover", "") != "":
				_cover_names[b.id] = last.cover
			continue  # nothing new on either side since it was last checked
		_set_progress("Syncing books (%d of %d)…" % [i + 1, all.size()])
		err = await _sync_book(dav, pool, b, folders, wanted, "Syncing books (%d of %d): %s" % [i + 1, all.size(), b.get("title", "")])
		if err != "":
			return err
		_cache.texts[b.id] = {"sig": sig, "cover": _cover_names.get(b.id, "")}
	for id in _cache.texts.keys():
		if not known.has(id):
			_cache.texts.erase(id)

	await _collect_garbage(dav, folders, remote)

	err = await _upload_own(dav, pool)
	if err != "":
		return err
	if _listed(listing, device_id() + ".json"):
		await dav.remove(FOLDER + "devices/%s.json" % device_id())  # written by an older version
	return ""


## Reads another device's index.json and the book files that changed since last
## time. -> {doc: index.json with each book's file merged into its entry}, {} when
## the device has nothing readable yet, or {error}.
func _fetch_device(dav: WebDav, pool: Array[WebDav], id: String) -> Dictionary:
	var base := FOLDER + "devices/" + id + "/"
	var l := await dav.list(base)
	if l.code == 404:
		return {}
	if not l.ok:
		return {"error": l.error}
	var etag := ""
	var found := false
	for e in l.entries:
		if e["name"] == "index.json":
			etag = e.etag
			found = true
	if not found:
		return {}  # being set up
	var c: Dictionary = _indexes.get(id, {})
	if c.is_empty() or etag == "" or c.etag != etag:
		var g := await dav.fetch(base + "index.json")
		if g.code == 404:
			return {}
		if not g.ok:
			return {"error": g.error}
		var data: Variant = JSON.parse_string(g.body.get_string_from_utf8())
		if not (data is Dictionary and data.get("books") is Array):
			return {}  # damaged or half-written; its device rewrites it on its next sync
		c = {"etag": etag, "data": data}
		_indexes[id] = c
	var index: Dictionary = c.data
	if not _cache.devices.has(id):
		_cache.devices[id] = {}
	var have: Dictionary = _cache.devices[id]
	if not _remote_books.has(id):
		_remote_books[id] = {}
	var loaded: Dictionary = _remote_books[id]

	var listed := {}
	var jobs := []
	for e in index.books:
		if not (e is Dictionary and e.get("key") is String and e.get("md5") is String):
			continue
		var key: String = e.key
		listed[key] = true
		if have.get(key, "") == e.md5:
			if not loaded.has(key):
				var path := _remote_path(id, key)
				var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
				if data is Dictionary:
					loaded[key] = data
			if loaded.has(key):
				continue
		jobs.append(key)
	if not jobs.is_empty():
		var work := {"done": 0, "total": jobs.size(), "name": index.get("device", {}).get("name", id)}
		var err := await _in_parallel(pool, jobs, _fetch_book_file.bind(id, work))
		if err != "":
			return {"error": err}
	for key in have.keys():
		if not listed.has(key):  # no longer on that device
			have.erase(key)
			loaded.erase(key)
			DirAccess.remove_absolute(_remote_path(id, key))

	var books := []
	for e in index.books:
		if e is Dictionary and loaded.has(e.get("key")):
			books.append(loaded[e.key].merged(e, true))
	var doc := index.duplicate()
	doc.books = books
	return {"doc": doc}


## One of another device's book files (a job for _in_parallel).
func _fetch_book_file(dav: WebDav, key: String, id: String, work: Dictionary) -> String:
	var g := await dav.fetch(FOLDER + "devices/%s/books/%s.json" % [id, _folder_name(key)])
	work.done += 1
	if work.total > 20 and Time.get_ticks_msec() - _progress_shown > 250:
		_progress_shown = Time.get_ticks_msec()
		_set_progress("Checking %s (%d of %d books)…" % [work.name, work.done, work.total])
	if g.code == 404:
		return ""  # removed meanwhile, or not uploaded yet; its index changes again soon
	if not g.ok:
		return g.error
	var text: String = g.body.get_string_from_utf8()
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return ""  # half-written; tried again next time
	_remote_books[id][key] = data
	_cache.devices[id][key] = text.md5_text()
	DirAccess.make_dir_recursive_absolute(_remote_dir() + "/" + id)
	var f := FileAccess.open(_remote_path(id, key), FileAccess.WRITE)
	if f:
		f.store_string(text)
	return ""


func _forget_device(id: String) -> void:
	_cache.devices.erase(id)
	_indexes.erase(id)
	_remote_books.erase(id)
	_remove_tree(_remote_dir() + "/" + id)


## Uploads this device's changed book files, then its index.json, then removes
## the files of books it no longer has.
func _upload_own(dav: WebDav, pool: Array[WebDav]) -> String:
	_set_progress("Saving…")
	var base := FOLDER + "devices/%s/" % device_id()
	var top := await dav.list(base)
	if top.code == 404:
		var m := await dav.make_dir(base)
		if not m.ok and m.code != 405:
			return m.error
		top = {"ok": true, "code": 207, "entries": []}
	elif not top.ok:
		return top.error
	var on_server := {}
	if _listed(top, "books"):
		var l := await dav.list(base + "books/")
		if not l.ok:
			return l.error
		for e in l.entries:
			if not e.is_dir:
				on_server[e["name"]] = true
	else:
		var m := await dav.make_dir(base + "books/")
		if not m.ok and m.code != 405:
			return m.error

	if not (_state.get("uploaded_books") is Dictionary):
		_state.uploaded_books = {}
	var uploaded: Dictionary = _state.uploaded_books
	var names := {}
	var entries := []
	var jobs := []
	for b in Library.books:
		var key := Library.sync_key(b)
		var name := _folder_name(key) + ".json"
		names[name] = true
		var cover: String = _cover_names.get(b.id, "")
		var rev: int = Library.revisions.get(b.id, 0)
		var md5 := ""
		var cached: Array = _md5s.get(b.id, [])
		if cached.size() == 3 and cached[0] == rev and cached[1] == cover:
			md5 = cached[2]
		var body := ""
		if md5 == "" or md5 != uploaded.get(key, "") or not on_server.has(name):
			body = JSON.stringify(_book_file(b))
			md5 = body.md5_text()
			_md5s[b.id] = [rev, cover, md5]
		if md5 != uploaded.get(key, "") or not on_server.has(name):
			jobs.append({"key": key, "path": base + "books/" + name, "body": body, "md5": md5})
		entries.append(_index_entry(b, key, md5))
	if not jobs.is_empty():
		var work := {"done": 0, "total": jobs.size()}
		var err := await _in_parallel(pool, jobs, _put_book_file.bind(work))
		if err != "":
			return err
	for key in uploaded.keys():
		if not Library.find_by_sync_key(key).is_empty():
			continue
		uploaded.erase(key)

	var doc := _device_doc(entries)
	var md5 := JSON.stringify(doc).md5_text()
	if md5 != _state.get("uploaded_md5", "") or not _listed(top, "index.json"):
		doc.updated = Time.get_unix_time_from_system()
		var r := await dav.put(base + "index.json", JSON.stringify(doc).to_utf8_buffer(), "application/json")
		if not r.ok:
			return r.error
		_state.uploaded_md5 = md5
	for name in on_server:
		if not names.has(name):
			await dav.remove(base + "books/" + name)  # a removed book; others know from the index
	return ""


func _put_book_file(dav: WebDav, job: Dictionary, work: Dictionary) -> String:
	var r := await dav.put(job.path, job.body.to_utf8_buffer(), "application/json")
	if not r.ok:
		return r.error
	_state.uploaded_books[job.key] = job.md5
	work.done += 1
	if work.total > 20 and Time.get_ticks_msec() - _progress_shown > 250:
		_progress_shown = Time.get_ticks_msec()
		_set_progress("Saving (%d of %d books)…" % [work.done, work.total])
	return ""


## Runs `job.call(dav, item) -> error or ""` for every item, on all the
## connections at once. -> the first error, or "".
func _in_parallel(pool: Array[WebDav], items: Array, job: Callable) -> String:
	var work := {"next": 0, "running": pool.size(), "error": ""}
	for d in pool:
		_parallel_worker(d, items, job, work)
	while work.running > 0:
		await get_tree().process_frame
	return work.error


func _parallel_worker(dav: WebDav, items: Array, job: Callable, work: Dictionary) -> void:
	while work.error == "" and work.next < items.size():
		var item: Variant = items[work.next]
		work.next += 1
		var err: String = await job.call(dav, item)
		if err != "" and work.error == "":
			work.error = err
	work.running -= 1


func _ensure_folders(dav: WebDav) -> String:
	var root := await dav.list(FOLDER)
	if root.code == 404:
		var r := await dav.make_dir(FOLDER)
		if not r.ok:
			return r.error
		root = {"ok": true, "entries": []}
	elif not root.ok:
		return root.error
	var names: Array = root.entries.map(func(e): return e["name"])
	for d in ["devices", "books", "plugins"]:
		if not d in names:
			var r := await dav.make_dir(FOLDER + d + "/")
			if not r.ok:
				return r.error
	return ""


static func _listed(listing: Dictionary, name: String) -> bool:
	return listing.entries.any(func(e): return e["name"] == name)


# --- merging -----------------------------------------------------------------

## Merges the other devices' state into this one. Returns {book key: {name, set}}:
## the cover file to use and when it was picked by hand (0: never).
func _merge(remote: Array) -> Dictionary:
	for d in remote:
		var tomb: Variant = d.get("tombstones", {})
		if tomb is Dictionary:
			for k in tomb:
				if float(tomb[k]) > float(Library.tombstones.get(k, 0.0)):
					Library.tombstones[k] = float(tomb[k])
					Library.save_index()

	var meta := {}    # key -> newest entry by modified
	var pos := {}     # key -> newest entry by last_read
	var all := {}     # key -> every entry
	var covers := {}
	for d in remote:
		for e in d.books:
			if not (e is Dictionary and e.has("key")):
				continue
			var k: String = e.key
			if not meta.has(k) or float(e.modified) > float(meta[k].modified):
				meta[k] = e
			if not pos.has(k) or float(e.last_read) > float(pos[k].last_read):
				pos[k] = e
			if not all.has(k):
				all[k] = []
			all[k].append(e)
			if e.get("cover", "") != "" and (not covers.has(k) or _cover_newer(e, covers[k])):
				covers[k] = e
	for k in covers:
		covers[k] = {"name": covers[k].cover, "set": float(covers[k].get("cover_set", 0))}

	for k in meta:
		var e: Dictionary = meta[k]
		var local := Library.find_by_sync_key(k)
		var activity := maxf(float(e.modified), float(pos[k].last_read))
		if not local.is_empty():
			activity = maxf(activity, _activity(local))
		if float(Library.tombstones.get(k, 0.0)) >= activity:
			if not local.is_empty():
				Library.remove_book(local.id, false)
			continue
		if local.is_empty():
			local = _create_book(k, e, all[k])
		else:
			_update_book(local, e, all[k])
		var marks := _merged_bookmarks(local, all[k])
		if marks != local.get("bookmarks", []):
			Library.set_bookmarks(local.id, marks)
		var p: Dictionary = pos[k]
		if float(p.last_read) > float(local.get("last_read", 0)):
			var prog: Dictionary = p.get("progress", {})
			var idx := _chapter_index_by_id(local, str(prog.get("id", "")))
			if idx < 0:
				idx = clampi(int(prog.get("chapter", 0)), 0, maxi(0, local.chapters.size() - 1))
			local.progress = {"chapter": idx, "paragraph": int(prog.get("paragraph", 0))}
			local.last_read = float(p.last_read)
			Library.save_index()
			Library.book_changed.emit(local.id)
			Library.changed.emit()

	for b in Library.books.duplicate():
		if float(Library.tombstones.get(Library.sync_key(b), 0.0)) >= _activity(b):
			Library.remove_book(b.id, false)

	_merge_rules(remote)
	_merge_settings(remote)
	return covers


## This book's bookmarks plus the other devices' ones: per bookmark, the most
## recently changed version wins (a removal too). Chapters are matched by id, as
## the chapter indexes can differ between devices.
static func _merged_bookmarks(local: Dictionary, entries: Array) -> Array:
	var out: Array = local.get("bookmarks", []).duplicate(true)
	var at := {}
	for i in out.size():
		at[out[i].id] = i
	for e in entries:
		var list: Variant = e.get("bookmarks", [])
		if not list is Array:
			continue
		for r in list:
			if not (r is Dictionary and r.has("id")):
				continue
			var i: int = at.get(r.id, -1)
			if i >= 0 and float(r.get("modified", 0)) <= float(out[i].modified):
				continue
			var ch := _chapter_index_by_id(local, str(r.get("chapter_id", "")))
			if ch < 0:
				ch = clampi(int(r.get("chapter", 0)), 0, maxi(0, local.chapters.size() - 1))
			var m := {
				"id": str(r.id), "chapter": ch, "paragraph": int(r.get("paragraph", 0)), "name": str(r.get("name", "")),
				"text": str(r.get("text", "")), "created": float(r.get("created", 0)), "modified": float(r.get("modified", 0)),
				"deleted": bool(r.get("deleted", false)),
			}
			if i >= 0:
				out[i] = m
			else:
				at[m.id] = out.size()
				out.append(m)
	return out


## The cover picked by hand last wins, else the one of the newest version.
static func _cover_newer(a: Dictionary, b: Dictionary) -> bool:
	var sa := float(a.get("cover_set", 0))
	var sb := float(b.get("cover_set", 0))
	return sa > sb if sa != sb else float(a.modified) > float(b.modified)


func _create_book(key: String, e: Dictionary, entries: Array) -> Dictionary:
	var chapters := _combined_chapters(_clean_chapters(e.get("chapters", [])), entries)
	return Library.add_book({
		"sync_key": key, "title": e.get("title", "Untitled"), "author": e.get("author", ""),
		"kind": e.get("kind", "web"), "source": e.get("source", "web"), "url": e.get("url", ""),
		"cover_url": e.get("cover_url", ""), "synopsis": e.get("synopsis", ""), "tags": e.get("tags", []),
		"extra": e.get("extra", {}), "rss_only": e.get("rss_only", false), "chapters": chapters,
		"total_words": int(e.get("total_words", 0)),
		"added": float(e.get("added", 0)), "last_checked": float(e.get("last_checked", 0)), "modified": float(e.modified),
	})


func _update_book(local: Dictionary, e: Dictionary, entries: Array) -> void:
	var remote_newer := float(e.modified) > float(local.modified)
	var stamp := maxf(float(e.modified), float(local.modified))
	var rss_only: bool = local.get("rss_only", false)
	var list_changed := false
	if _has_urls(local.chapters):
		var base: Array = _clean_chapters(e.get("chapters", [])) if remote_newer else local.chapters
		var others: Array = [{"chapters": local.chapters}] + entries if remote_newer else entries
		var merged := _combined_chapters(base, others)
		if _chapter_ids(merged) != _chapter_ids(local.chapters):
			Library.replace_chapters(local.id, merged)
	else:
		var longer := _extended_chapters(local.chapters, entries)
		if longer.size() > local.chapters.size():
			for i in local.chapters.size():  # same chapters at the start: keep their word counts
				if local.chapters[i].has("words"):
					longer[i].words = local.chapters[i].words
			local.chapters = longer
			list_changed = true
	var fields := {"modified": stamp}
	if remote_newer:
		for f in ["title", "author", "synopsis", "tags", "extra", "cover_url", "rss_only", "url", "source", "kind", "total_words"]:
			if e.has(f):
				fields[f] = e[f]
	else:
		fields.rss_only = rss_only  # replace_chapters clears it
	fields.last_checked = maxf(float(local.get("last_checked", 0)), float(e.get("last_checked", 0)))
	if list_changed or fields.keys().any(func(f): return local.get(f) != fields[f]):
		Library.update_book(local.id, fields)


## Imported books have no chapter URLs, and chapters are only ever added to their
## end (a later part of a serial, see Library.append_chapters): the longest of the
## other devices' lists that starts with this one, else this one.
static func _extended_chapters(chapters: Array, entries: Array) -> Array:
	var best := chapters
	for e in entries:
		var list: Array = _clean_chapters(e.get("chapters", []))
		if list.size() <= best.size() or (_has_urls(list) and not chapters.is_empty()):
			continue
		var prefix := true
		for i in chapters.size():
			if list[i].title != chapters[i].title:
				prefix = false
				break
		if prefix:
			best = list
	return best


## The base list in its order, plus chapters only the other lists have, each placed
## right after the chapter it follows there (or at the end).
static func _combined_chapters(base: Array, entries: Array) -> Array:
	var out := base.duplicate()
	if not _has_urls(out) and not out.is_empty():
		return out
	var pos := {}
	for i in out.size():
		pos[_chapter_id_of(out[i], i)] = i
	for e in entries:
		var prev := ""
		var list: Array = _clean_chapters(e.get("chapters", []))
		for i in list.size():
			var id := _chapter_id_of(list[i], i)
			if not pos.has(id):
				var at: int = pos[prev] + 1 if pos.has(prev) else out.size()
				out.insert(at, list[i])
				pos.clear()
				for j in out.size():
					pos[_chapter_id_of(out[j], j)] = j
			prev = id
	return out


static func _clean_chapters(list: Array) -> Array:
	var out := []
	for c in list:
		if c is Dictionary:
			out.append({"title": str(c.get("title", "")), "url": str(c.get("url", "")), "date": c.get("date", 0)})
	return out


static func _has_urls(chapters: Array) -> bool:
	return chapters.any(func(c): return c.get("url", "") != "")


static func _chapter_ids(chapters: Array) -> Array:
	var out := []
	for i in chapters.size():
		out.append(_chapter_id_of(chapters[i], i))
	return out


## Chapters with a URL are identified by it (indexes shift when a chapter list is
## completed); imported books have no URLs and only get chapters added at the end,
## so they use the index.
static func _chapter_id_of(chapter: Dictionary, index: int) -> String:
	var url: String = chapter.get("url", "")
	return Library.chapter_key(url).md5_text().left(16) if url != "" else "n%d" % index


static func _chapter_index_by_id(book: Dictionary, id: String) -> int:
	if id == "":
		return -1
	for i in book.chapters.size():
		if _chapter_id_of(book.chapters[i], i) == id:
			return i
	return -1


static func _activity(book: Dictionary) -> float:
	return maxf(maxf(float(book.get("modified", 0)), float(book.get("last_read", 0))), float(book.get("added", 0)))


func _merge_rules(remote: Array) -> void:
	var best := {}
	var stamp := TextRules.modified
	for d in remote:
		var r: Variant = d.get("rules")
		if r is Dictionary and r.get("list") is Array and float(r.get("modified", 0)) > stamp:
			best = r
			stamp = float(r.modified)
	if best.is_empty():
		return
	var list := []
	for r in best.list:
		if r is Dictionary:
			var c: Dictionary = r.duplicate()
			var book: String = c.get("book", "")
			if book.begins_with("sync:"):
				var local := Library.find_by_sync_key(book.trim_prefix("sync:"))
				if not local.is_empty():
					c.book = local.id
			list.append(c)
	TextRules.apply_synced(list, stamp)


func _merge_settings(remote: Array) -> void:
	var best := {}
	for d in remote:
		var s: Variant = d.get("settings")
		if not (s is Dictionary):
			continue
		for k in s:
			if s[k] is Dictionary and float(s[k].get("t", 0)) > float(Settings.stamps.get(k, 0)) \
					and (not best.has(k) or float(s[k].t) > float(best[k].t)):
				best[k] = s[k]
	for k in best:
		var v: Variant = best[k].get("v")
		if typeof(v) == TYPE_FLOAT and typeof(Settings.DEFAULTS.get(k)) == TYPE_INT:
			v = int(v)
		Settings.apply_synced(k, v, float(best[k].t))


## This device's index.json (without `updated`); `books` from _index_entry.
func _device_doc(books: Array) -> Dictionary:
	var settings := {}
	for k in Settings.DEFAULTS:
		if not k in Settings.LOCAL_ONLY and Settings.stamps.has(k):
			settings[k] = {"v": Settings.get_value(k), "t": Settings.stamps[k]}
	var rules := []
	for r in TextRules.rules:
		var c: Dictionary = r.duplicate()
		var b := Library.get_book(c.book) if c.book != "" else {}
		if not b.is_empty():
			c.book = "sync:" + Library.sync_key(b)
		rules.append(c)
	return {
		"version": 2,
		"device": {"id": device_id(), "name": device_name(), "platform": OS.get_name()},
		"books": books,
		"tombstones": Library.tombstones,
		"rules": {"modified": TextRules.modified, "list": rules},
		"settings": settings,
		"plugins": Plugins.sync_records(),
	}


## A book's entry in index.json: what changes often, and the md5 of its book file.
## `texts` tells other devices it has new chapter text (see _texts_sig).
static func _index_entry(b: Dictionary, key: String, md5: String) -> Dictionary:
	var p: Dictionary = b.progress
	var at: int = p.chapter
	return {
		"key": key, "md5": md5, "modified": b.modified, "last_read": b.last_read, "texts": b.get("text_stamp", 0),
		"progress": {"id": _chapter_id_of(b.chapters[at], at) if at < b.chapters.size() else "", "chapter": at, "paragraph": p.paragraph},
	}


## A book's file in devices/<id>/books/: everything but what's in its index entry.
func _book_file(b: Dictionary) -> Dictionary:
	var out := {
		"key": Library.sync_key(b), "title": b.title, "author": b.author, "kind": b.kind, "source": b.source,
		"url": b.url, "cover_url": b.cover_url, "synopsis": b.synopsis, "tags": b.tags, "extra": b.get("extra", {}),
		"rss_only": b.get("rss_only", false), "added": b.added, "last_checked": b.last_checked,
		"chapters": _clean_chapters(b.chapters),
		"cover": _cover_names.get(b.id, ""), "cover_set": b.get("cover_set", 0),
		"bookmarks": b.get("bookmarks", []).map(func(m):
			var c: int = m.chapter
			return m.merged({"chapter_id": _chapter_id_of(b.chapters[c], c) if c < b.chapters.size() else ""})),
	}
	if int(b.get("total_words", 0)) > 0:  # only when set, so other books' files stay the same
		out.total_words = int(b.total_words)
	return out


## Book key -> the other devices' text stamps for it, as one string.
static func _remote_texts(remote: Array) -> Dictionary:
	var lists := {}
	for d in remote:
		for e in d.books:
			if e is Dictionary and e.has("key"):
				if not lists.has(e.key):
					lists[e.key] = []
				lists[e.key].append(str(e.get("texts", 0)))
	var out := {}
	for k in lists:
		lists[k].sort()
		out[k] = ",".join(lists[k])
	return out


## Sums up what decides whether a book's chapters and cover need syncing: its
## chapter text and list here, its cover, the cover wanted, and the other devices'
## chapter text. When it's the same as after the last check, nothing has to be
## listed or sent for the book.
static func _texts_sig(b: Dictionary, on_server: bool, wanted: Dictionary, remote_texts: String) -> String:
	return "%s|%d|%s|%s|%s|%s|%s|%s" % [b.get("text_stamp", 0), b.chapters.size(), b.cover, b.get("cover_set", 0),
		wanted.get("name", ""), wanted.get("set", 0), remote_texts, on_server]


# --- plugins -----------------------------------------------------------------

## Install, update or remove plugins as other devices did, then upload the
## plugins this device has that the server doesn't have yet.
func _sync_plugins(dav: WebDav, remote: Array) -> String:
	var newest := {}  # id -> the most recent record of any other device
	for d in remote:
		var pl: Variant = d.get("plugins")
		if not (pl is Dictionary):
			continue
		for id in pl:
			if pl[id] is Dictionary and (not newest.has(id) or float(pl[id].get("t", 0)) > float(newest[id].get("t", 0))):
				newest[id] = pl[id]
	var mine := Plugins.sync_records()
	for id in newest:
		var r: Dictionary = newest[id]
		var m: Dictionary = mine.get(id, {})
		if float(r.get("t", 0)) <= float(m.get("t", 0)):
			continue
		if r.get("removed", false):
			if Plugins.is_installed(id):
				Plugins.remove(id, float(r.t))
			continue
		if not Plugins.get_entry(id).is_empty() and not m.get("removed", false) and Plugins.compare_versions(str(r.get("v", "")), str(m.get("v", ""))) <= 0:
			continue  # already have this version (or a newer one)
		_set_progress("Installing plugin %s…" % id)
		await _download_plugin(dav, id, str(r.get("v", "")), float(r.get("t", 0)))

	var listing := await dav.list(FOLDER + "plugins/")
	if not listing.ok:
		return listing.error
	var have := Plugins.sync_records()
	for id in have:
		var r: Dictionary = have[id]
		if r.get("removed", false):
			continue
		var files := Plugins.files_of(id)
		if files.is_empty():
			continue  # not all its files are readable here (e.g. an exported build)
		var folder := FOLDER + "plugins/%s/%s/" % [id, r.v]
		if _listed(listing, id):
			var versions := await dav.list(FOLDER + "plugins/%s/" % id)
			if versions.ok and _listed(versions, str(r.v)):
				continue
		_set_progress("Uploading plugin %s…" % id)
		var made := {}
		for rel in files:
			if rel == Plugins.MANIFEST:
				continue
			var err := await _put_plugin_file(dav, folder, rel, files[rel], made)
			if err != "":
				return err
		var err := await _put_plugin_file(dav, folder, Plugins.MANIFEST, files[Plugins.MANIFEST], made)  # last: marks it complete
		if err != "":
			return err
	return ""


## Upload one file of a plugin, creating its folders on the way (`made` remembers them).
func _put_plugin_file(dav: WebDav, folder: String, rel: String, path: String, made: Dictionary) -> String:
	var base := FOLDER + "plugins/"
	var dirs := (folder.trim_prefix(base) + rel).split("/")
	var at := base
	for i in dirs.size() - 1:
		at += dirs[i] + "/"
		if made.has(at):
			continue
		var r := await dav.make_dir(at)
		if not r.ok and r.code != 405:  # 405: it's already there
			return r.error
		made[at] = true
	var put := await dav.put(folder + rel, FileAccess.get_file_as_bytes(path))
	return "" if put.ok else put.error


## Install a plugin version from the server. Reads its plugin.json first and
## skips a plugin that can't run here without downloading its files. Any failure
## only skips this plugin (it's tried again next time); the rest of the sync goes on.
func _download_plugin(dav: WebDav, id: String, version: String, stamp: float) -> void:
	var folder := FOLDER + "plugins/%s/%s/" % [id, version]
	var g := await dav.fetch(folder + Plugins.MANIFEST)
	if not g.ok:
		if g.code != 404:  # 404: not uploaded completely yet
			print("Sync: plugin %s: couldn't download %s (%s)" % [id, Plugins.MANIFEST, g.error])
		return
	var m: Variant = JSON.parse_string(g.body.get_string_from_utf8())
	if not (m is Dictionary):
		print("Sync: plugin %s: %s is damaged" % [id, Plugins.MANIFEST])
		return
	var why := Plugins.check_manifest(m)
	if why != "":  # e.g. a desktop-only plugin on a phone
		print("Sync: plugin %s: skipped: %s" % [id, why])
		return
	var files := {Plugins.MANIFEST: g.body}
	for rel in m.get("files", []):
		var f := await dav.fetch(folder + str(rel))
		if not f.ok:
			print("Sync: plugin %s: couldn't download %s (%s)" % [id, rel, f.error])
			return
		files[str(rel)] = f.body
	var r := Plugins.install_files(m, files, stamp)
	if r.has("error"):
		print("Sync: plugin %s: %s" % [id, r.error])


# --- chapters and covers -----------------------------------------------------

static func _folder_name(key: String) -> String:
	return key.md5_text().left(20)


func _sync_book(dav: WebDav, pool: Array[WebDav], b: Dictionary, folders: Dictionary, wanted: Dictionary, label := "") -> String:
	var key := Library.sync_key(b)
	var folder := FOLDER + "books/" + _folder_name(key) + "/"
	var exists := folders.has(_folder_name(key))
	var remote := {}
	if exists:
		var l := await dav.list(folder)
		if l.ok:
			for e in l.entries:
				remote[e["name"]] = e.size
		elif l.code == 404:
			exists = false
		else:
			return l.error
	var done: Dictionary = _done.get(b.id, {})
	_done[b.id] = done

	# work out what to send and fetch, then do it over several connections
	var jobs := []  # [{name, up}]
	for i in b.chapters.size():
		var name := _chapter_id_of(b.chapters[i], i) + ".json"
		if remote.has(name) and done.has(name):
			continue
		var local_full := Library.has_full_chapter(b.id, i)
		if remote.has(name) and not local_full:
			jobs.append({"name": name, "up": false})
		elif local_full and (not remote.has(name) or int(remote[name]) == 0):
			jobs.append({"name": name, "up": true})
		elif remote.has(name) and local_full:
			done[name] = true
	if not exists and jobs.any(func(j): return j.up):
		var m := await dav.make_dir(folder)
		if not m.ok:
			return m.error
		exists = true
	if not jobs.is_empty():
		var work := {"jobs": jobs, "next": 0, "finished": 0, "running": pool.size(), "error": "",
			"book": b, "folder": folder, "done": done, "label": label, "index": {}, "chapters": null}
		for d in pool:
			_chapter_worker(d, work)
		while work.running > 0:
			await get_tree().process_frame
		if work.error != "":
			return work.error
		if Library.get_book(b.id).is_empty():
			return ""

	var cover: String = wanted.get("name", "")
	var have_cover: bool = b.cover != "" and FileAccess.file_exists(b.cover)
	var local_name := "cover-%s.png" % FileAccess.get_md5(b.cover).left(12) if have_cover else ""
	# another device picked a different cover by hand after this one's was set
	var replace: bool = have_cover and cover != "" and cover != local_name and remote.has(cover) \
		and float(wanted.get("set", 0)) > float(b.get("cover_set", 0))
	if have_cover and not replace:
		var name := local_name
		if not remote.has(name):
			if not exists:
				var m := await dav.make_dir(folder)
				if not m.ok:
					return m.error
			var r := await dav.put(folder + name, FileAccess.get_file_as_bytes(b.cover), "image/png")
			if not r.ok:
				return r.error
		_cover_names[b.id] = name
	elif cover != "" and remote.has(cover):
		var g := await dav.fetch(folder + cover)
		if g.ok and Image.new().load_png_from_buffer(g.body) == OK and not Library.get_book(b.id).is_empty():
			DirAccess.make_dir_recursive_absolute(Settings.data_dir() + "/covers")
			var path := "%s/covers/%s.png" % [Settings.data_dir(), b.id]
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f:
				f.store_buffer(g.body)
				f.close()
				_applying = true
				Library.update_book(b.id, {"cover": path, "cover_set": float(wanted.get("set", 0)), "modified": b.modified})
				_applying = false
				_cover_names[b.id] = cover
	return ""


## Takes chapter jobs from `work` until none are left or one fails (work.error).
## Several of these run at once, each on its own connection.
func _chapter_worker(dav: WebDav, work: Dictionary) -> void:
	var b: Dictionary = work.book
	var jobs: Array = work.jobs
	while work.error == "" and work.next < jobs.size() and not Library.get_book(b.id).is_empty():
		var job: Dictionary = jobs[work.next]
		work.next += 1
		var name: String = job.name
		var r: Dictionary
		if job.up:
			var at := _job_index(work, name.get_basename())
			if at < 0:
				continue
			r = await dav.put(work.folder + name, FileAccess.get_file_as_bytes("%s/%d.json" % [Library.book_dir(b.id), at]), "application/json")
			if r.ok:
				work.done[name] = true
		else:
			r = await dav.fetch(work.folder + name)
			if r.ok and not Library.get_book(b.id).is_empty():
				var ch: Variant = JSON.parse_string(r.body.get_string_from_utf8())
				# the chapter list may have changed while downloading; find the chapter again
				var at := _job_index(work, name.get_basename())
				if ch is Dictionary and ch.get("paragraphs") is Array and at >= 0:
					Library.store_chapter(b.id, at, str(ch.get("title", b.chapters[at].title)), PackedStringArray(ch.paragraphs))
					work.done[name] = true
		if not r.ok:
			work.error = r.error
			break
		work.finished += 1
		# shown at most a few times a second; a big book can take many minutes
		if work.label != "" and Time.get_ticks_msec() - _progress_shown > 250:
			_progress_shown = Time.get_ticks_msec()
			_set_progress("%s, %d of %d chapters…" % [work.label, work.finished, jobs.size()])
	work.running -= 1


## A chapter's current index by its id, from a map that's rebuilt only when the
## book's chapter list has changed (looking each one up anew is slow for big books).
func _job_index(work: Dictionary, id: String) -> int:
	var b: Dictionary = work.book
	var at: int = work.index.get(id, -1)
	if work.chapters != null and is_same(work.chapters, b.chapters) and at >= 0 and at < b.chapters.size() \
			and _chapter_id_of(b.chapters[at], at) == id:
		return at
	work.chapters = b.chapters
	work.index = {}
	for i in b.chapters.size():
		work.index[_chapter_id_of(b.chapters[i], i)] = i
	return work.index.get(id, -1)


## Deletes the server folders of books removed more than GC_AFTER ago that no
## device has anymore.
func _collect_garbage(dav: WebDav, folders: Dictionary, remote: Array) -> void:
	var live := {}
	for b in Library.books:
		live[Library.sync_key(b)] = true
	for d in remote:
		for e in d.books:
			if e is Dictionary:
				live[e.get("key", "")] = true
	var now := Time.get_unix_time_from_system()
	for k in Library.tombstones:
		if now - float(Library.tombstones[k]) > GC_AFTER and not live.has(k) and folders.has(_folder_name(k)):
			await dav.remove(FOLDER + "books/" + _folder_name(k) + "/")


# --- local state -------------------------------------------------------------

func _state_path() -> String:
	return Settings.data_dir() + "/sync.json"


func _cache_path() -> String:
	return Settings.data_dir() + "/sync_cache.json"


## Other devices' book files, as last downloaded: sync_devices/<device id>/<hash>.json
func _remote_dir() -> String:
	return Settings.data_dir() + "/sync_devices"


func _remote_path(id: String, key: String) -> String:
	return "%s/%s/%s.json" % [_remote_dir(), id, _folder_name(key)]


static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for d in dir.get_directories():
		_remove_tree(path.path_join(d))
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(path)


func _secret_path() -> String:
	return Settings.data_dir() + "/sync_secret.dat"


func _load_state() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_state_path())) if FileAccess.file_exists(_state_path()) else null
	_state = parsed if parsed is Dictionary else {}
	if _state.get("device_id", "") == "":
		_state.device_id = "%x%08x" % [int(Time.get_unix_time_from_system()), randi()]
	if _state.get("device_name", "") == "":
		_state.device_name = _default_device_name()
	last_sync = float(_state.get("last_sync", 0))
	var cache: Variant = JSON.parse_string(FileAccess.get_file_as_string(_cache_path())) if FileAccess.file_exists(_cache_path()) else null
	if cache is Dictionary and cache.get("devices") is Dictionary and cache.get("texts") is Dictionary:
		_cache = cache
	else:
		_remove_tree(_remote_dir())
	var f := FileAccess.open_encrypted_with_pass(_secret_path(), FileAccess.READ, _secret_key())
	if f:
		_password = f.get_as_text()
	_save_state()


func _save_state() -> void:
	var f := FileAccess.open(_state_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_state, "\t"))


func _save_cache() -> void:
	var f := FileAccess.open(_cache_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_cache))


## The password is stored encrypted with a key tied to this device. That keeps it
## out of plain view in the data folder; it isn't strong protection.
func _save_password() -> void:
	var f := FileAccess.open_encrypted_with_pass(_secret_path(), FileAccess.WRITE, _secret_key())
	if f:
		f.store_string(_password)


static func _secret_key() -> String:
	return "serial-reader-sync:" + OS.get_unique_id()


static func _default_device_name() -> String:
	var model := OS.get_model_name()
	if OS.has_feature("mobile") and model != "" and model != "GenericDevice":
		return "%s (%s)" % [model, OS.get_name()]
	var host := OS.get_environment("COMPUTERNAME")
	if host == "" and OS.get_name() == "macOS":
		var out := []
		if OS.execute("/usr/sbin/scutil", ["--get", "ComputerName"], out) == 0 and not out.is_empty():
			host = str(out[0]).strip_edges()
	if host == "" and FileAccess.file_exists("/etc/hostname"):
		host = FileAccess.get_file_as_string("/etc/hostname").strip_edges()
	return "%s (%s)" % [host, OS.get_name()] if host != "" else OS.get_name()
