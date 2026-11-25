extends Node
## Keeps the library, reading positions, text rules and settings the same on all
## your devices, through a folder on a WebDAV server (Nextcloud, Koofr, ...).
##
## Layout inside <server address>/bibliotheca-viva/:
##   devices/<device id>/       one per device; only that device ever writes in it
##     index.json               settings, text rules, plugins, removed books, per
##                              book: reading position, timestamps, and the md5 of
##                              its file below, so others fetch only changed books;
##                              and `missing`: chapters other devices say are on
##                              the server that it didn't find there
##     books/<hash>.json        a book's details, chapter list and bookmarks, and
##                              which of its chapters that device knows are in the
##                              book's folder below (on_server, see _flags)
##   books/<hash of book key>/  one folder per book
##     <chapter id>.json        chapter text; written once, never changed
##     pack-<md5>.json.gz       many chapters' text in one gzipped file, for when a
##                              lot of chapters are sent at once (a book's first
##                              upload); written once, never changed
##     pack-<md5>.ids.json      the ids of the chapters in that pack; written after
##                              it, so a pack without one is ignored
##     cover-<md5>.png          cover image; named by its content, never changed
##   plugins/<id>/<version>/    an installed plugin's files; written once
##
## No file is written by two devices, so one device can't overwrite another's
## changes, and the server's folder listing is the only index (nothing to drift).
## Each sync step can be repeated safely, so an interrupted sync is finished by
## the next one. Each device reads the other devices' files and merges them into
## its library:
##   - book details: the most recently changed version wins
##     (except dropped, archived and favorite: the most recent change of each wins,
##     see SyncMerge.status_fields)
##   - reading position: the most recently read version wins
##   - chapter lists: combined, so chapters saved on either device are kept
##     (an imported book's list only grows at the end: the longest one wins)
##   - chapter text: a book's folder is looked at when this device has a chapter
##     that isn't known to be on the server, or lacks one that is (known from
##     the folder when it was last listed, or from another device's on_server).
##     No timestamps: what's missing on either side is fetched or sent, and a
##     chapter that fails is simply still missing next time. A device sends a
##     chapter it has when it hasn't seen it on the server itself, whatever the
##     others say. A chapter another device says is there but isn't (removed
##     on the server, say) goes in `missing`; a device that has the chapter then
##     looks at the folder again and sends it, and the entry goes once the
##     chapter is there or no device says it is anymore
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
const PACK_MIN := 10         # chapters of a book to send at once before they go in packs
const PACK_BYTES := 2000000  # most chapter text in one pack, before it's gzipped
const PACK_GZIP_MAX := PACK_BYTES * 8  # biggest unpacked pack accepted; a pack holds at most PACK_BYTES of chapter text, the margin covers the JSON envelope and escaping

var running := false
var last_error := ""
var last_sync := 0.0
var progress_text := ""
var _progress_base := ""     # progress_text without a note about waiting for the server
var _progress_shown := 0     # ticks when chapter progress was last shown
var devices: Array = []      # [{id, name, platform, updated}] other devices on the server

var _state := {}             # enabled, url, user, device_id, device_name, last_sync, uploaded_md5, uploaded_books
var _password := ""
var _password_ready := false  # false until it's been read from where it's kept
var _plugins := SyncPlugins.new(self)
var _chapters := SyncChapters.new(self)
var _secret := SyncSecret.new(self)
## Kept in sync_cache.json; the other devices' book files are kept in sync_devices/.
##   devices: device id -> {book key: md5 of its book file as cached}
##   server: book id -> {chapter id: true}: its chapters known to be in its
##     server folder (listed there, or sent or fetched by this device)
##   local: book id -> {stamp, full: [chapter indexes]}: its chapters saved here
##     with their full text, as of its text_stamp (saves opening every file)
##   covers: book id -> {sig, cover}: the state of its cover when it was last
##     found to be on both sides (see SyncMerge.cover_sig)
##   missing: book id -> [chapter ids]: what goes in index.json's `missing`
var _cache := _empty_cache()
var _indexes := {}           # device id -> {etag, data}: other devices' index.json
var _remote_books := {}      # device id -> {book key: data}: their book files, loaded
var _md5s := {}              # book id -> [revision, cover, on_server flags, md5] of this device's book file
var _done := {}              # book id -> {chapter file name: true} known to be on both sides
var _cover_names := {}       # book id -> remote cover file name
var _pack_ids := {}          # server path of a pack's .ids.json -> its chapter ids (packs never change)
var _ids := {}               # book id -> {list, size, ids}: its chapter ids, while its chapter list stays the same
var _flagged := {}           # "<device id>|<book key>" -> [md5 of the book file, {chapter id: true} it has on_server]
var _dirty := false
var _again := false
var _applying := false
var _closing := false
var _debounce: Timer
var _periodic: Timer


func _ready() -> void:
	_load_state()
	_secret.load_password()
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
	if _password_ready:
		return _password != ""
	return _state.get("password_in", "") != "" or FileAccess.file_exists(_secret.secret_path())


## Where the password is kept on this device, for the settings page.
func password_store_name() -> String:
	if _state.get("password_in", "") != "file" and Keyring.backend_name() != "":
		return Keyring.backend_name()
	return "an encrypted file in the app's data folder (no system keyring found)"


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
		_cache = _empty_cache()
		_indexes.clear()
		_flagged.clear()
		_remote_books.clear()
		_remove_tree(_remote_dir())
		_done.clear()
		# _pack_ids and _cover_names name files on the server, which another
		# server reuses for other packs and covers. _md5s and _ids stay: they
		# describe this device's files and check themselves before use (the
		# server's on_server flags are part of the _md5s key, and _ids is
		# only used while the chapter list is the same object).
		_pack_ids.clear()
		_cover_names.clear()
		_state.uploaded_md5 = ""
		_state.uploaded_books = {}
	_state.url = url
	_state.user = user.strip_edges()
	if password != "":
		_password = password
		_password_ready = true
		_secret.save_password()
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
	await _secret.wait_for_password()
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
	var t := Time.get_ticks_msec()
	AppLog.info("sync", "started" + (" (by hand)" if manual else ""))
	var err := await _run()
	AppLog.info("sync", ("done in %d ms" if err == "" else "failed after %d ms: ") % AppLog.since(t) + err)
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
		AppLog.info("close", "syncing changes first (waits at most %d s)" % CLOSE_WAIT)
		get_tree().create_timer(CLOSE_WAIT).timeout.connect(func():
			AppLog.info("close", "sync took too long, quitting anyway")
			get_tree().quit())
		await sync_now()
	AppLog.info("close", "sync finished, quitting")
	get_tree().quit()


func _set_progress(text: String) -> void:
	progress_text = text
	_progress_base = text
	status_changed.emit()


# --- the sync ----------------------------------------------------------------

func _run() -> String:
	await _secret.wait_for_password()
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
	err = await _plugins.sync_plugins(dav, remote)
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
	var flagged := _remote_flags(remote)
	_take_requests(remote)
	var all := Library.books.duplicate()
	var known := {}
	for i in all.size():
		var b: Dictionary = all[i]
		if Library.get_book(b.id).is_empty():
			continue
		known[b.id] = true
		var key := Library.sync_key(b)
		var wanted: Dictionary = covers.get(key, {})
		var exists := folders.has(SyncChapters.folder_name(key))
		if not exists:
			_cache.server.erase(b.id)  # its folder is gone (or never was): nothing of it is there
		var sig := SyncMerge.cover_sig(b, exists, wanted)
		var last: Dictionary = _cache.covers.get(b.id, {})
		if last.get("sig", "") == sig and not _chapters_differ(b, flagged.get(key, {})):
			if last.get("cover", "") != "":
				_cover_names[b.id] = last.cover
			_cache.missing.erase(b.id)  # no chapter it lacks is said to be there anymore
			continue  # every chapter is on both sides, as far as is known
		_set_progress("Syncing books (%d of %d)…" % [i + 1, all.size()])
		err = await _chapters.sync_book(dav, pool, b, folders, wanted, flagged.get(key, {}), "Syncing books (%d of %d): %s" % [i + 1, all.size(), b.get("title", "")])
		if err != "":
			return err
		_cache.covers[b.id] = {"sig": sig, "cover": _cover_names.get(b.id, "")}
	for part in ["covers", "server", "local", "missing"]:
		for id in _cache[part].keys():
			if not known.has(id):
				_cache[part].erase(id)
	for id in _ids.keys():
		if not known.has(id):
			_ids.erase(id)

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
	# Malformed entries never reach the merge: without this, one damaged
	# entry aborts _merge halfway (a GDScript runtime error only ends the
	# function it hits) and leaves the library half-merged.
	var checked := SyncMerge.sanitize_device_doc(index)
	if (checked.doc as Dictionary).is_empty():
		return {}
	index = checked.doc
	c.data = index
	if int(checked.dropped) > 0:
		var dev: Dictionary = index.get("device", {})
		print("Sync: dropped %d malformed entries from device %s" % [checked.dropped, str(dev.get("name", id))])
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
	var g := await dav.fetch(FOLDER + "devices/%s/books/%s.json" % [id, SyncChapters.folder_name(key)])
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
	SafeFile.write_text(_remote_path(id, key), text)
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
		var name := SyncChapters.folder_name(key) + ".json"
		names[name] = true
		var cover: String = _cover_names.get(b.id, "")
		var rev: int = Library.revisions.get(b.id, 0)
		var flags := _flags(b)
		var md5 := ""
		var cached: Array = _md5s.get(b.id, [])
		if cached.size() == 4 and cached[0] == rev and cached[1] == cover and cached[2] == flags:
			md5 = cached[3]
		var body := ""
		if md5 == "" or md5 != uploaded.get(key, "") or not on_server.has(name):
			body = JSON.stringify(_book_file(b, flags))
			md5 = body.md5_text()
			_md5s[b.id] = [rev, cover, flags, md5]
		if md5 != uploaded.get(key, "") or not on_server.has(name):
			jobs.append({"key": key, "path": base + "books/" + name, "body": body, "md5": md5})
		entries.append(SyncMerge.index_entry(b, key, md5, Library.chapter_key))
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

	var grouped := SyncMerge.group_by_key(remote)
	var covers := {}
	for k in grouped:
		var pick := SyncMerge.pick_cover(grouped[k].all)
		if not pick.is_empty():
			covers[k] = pick

	for k in grouped:
		var e: Dictionary = grouped[k].meta
		var local := Library.find_by_sync_key(k)
		var activity := maxf(SyncMerge.num(e.get("modified", 0)), SyncMerge.num(grouped[k].pos.get("last_read", 0)))
		if not local.is_empty():
			activity = maxf(activity, SyncMerge.activity_of(local))
		if SyncMerge.tombstone_removes(SyncMerge.num(Library.tombstones.get(k, 0.0)), activity):
			if not local.is_empty():
				Library.remove_book(local.id, false)
			continue
		if local.is_empty():
			local = _create_book(k, e, grouped[k].all)
		else:
			_update_book(local, e, grouped[k].all)
		var marks := _merged_bookmarks(local, grouped[k].all)
		if marks != local.get("bookmarks", []):
			Library.set_bookmarks(local.id, marks)
		var moving := SyncMerge.newer_progress(local, grouped[k].pos, Library.chapter_key)
		if not moving.is_empty():
			local.progress = moving.progress
			local.last_read = float(moving.last_read)
			Library.save_index()
			Library.book_changed.emit(local.id)
			Library.changed.emit()

	for b in Library.books.duplicate():
		if SyncMerge.tombstone_removes(SyncMerge.num(Library.tombstones.get(Library.sync_key(b), 0.0)), SyncMerge.activity_of(b)):
			Library.remove_book(b.id, false)

	_merge_rules(remote)
	_merge_settings(remote)
	return covers


## SyncMerge's rule with this app's chapter keys.
static func _merged_bookmarks(local: Dictionary, entries: Array) -> Array:
	return SyncMerge.merged_bookmarks(local, entries, Library.chapter_key)


func _create_book(key: String, e: Dictionary, entries: Array) -> Dictionary:
	var chapters := SyncMerge.combined_chapters(SyncMerge.clean_chapters(e.get("chapters", [])), entries, Library.chapter_key)
	return Library.add_book({
		"sync_key": key, "title": e.get("title", "Untitled"), "author": e.get("author", ""),
		"kind": e.get("kind", "web"), "source": e.get("source", "web"), "url": e.get("url", ""),
		"cover_url": e.get("cover_url", ""), "synopsis": e.get("synopsis", ""), "tags": e.get("tags", []),
		"tags_set": bool(e.get("tags_set", false)),
		"extra": e.get("extra", {}), "rss_only": e.get("rss_only", false), "chapters": chapters,
		"total_words": SyncMerge.to_int(e.get("total_words", 0)),
		"added": SyncMerge.num(e.get("added", 0)), "last_checked": SyncMerge.num(e.get("last_checked", 0)), "modified": SyncMerge.num(e.get("modified", 0)),
		"last_full_check": SyncMerge.num(e.get("last_full_check", 0)), "possible_gap": bool(e.get("possible_gap", false)),
	}.merged(SyncMerge.status_fields({}, entries)))


func _update_book(local: Dictionary, e: Dictionary, entries: Array) -> void:
	var remote_newer := SyncMerge.num(e.get("modified", 0)) > SyncMerge.num(local.get("modified", 0))
	# Decided before replace_chapters, which stamps `modified` with now: after
	# it, this device's version would always look newer and the other device's
	# details (an archive, an edit) would be dropped whenever its chapter list
	# had chapters this one lacks.
	var fields := SyncMerge.detail_fields(local, e, entries)
	var list_changed := false
	var merged := SyncMerge.updated_chapters(local.chapters, e, entries, remote_newer, Library.chapter_key)
	if SyncMerge.has_urls(local.chapters):
		if SyncMerge.chapter_ids(merged, Library.chapter_key) != _chapter_ids(local.chapters):
			Library.replace_chapters(local.id, merged)
			list_changed = true  # writes `modified` back from fields
	elif merged.size() > local.chapters.size():
		for i in local.chapters.size():  # same chapters at the start: keep their word counts
			if local.chapters[i].has("words"):
				merged[i].words = local.chapters[i].words
		local.chapters = merged
		list_changed = true
	if list_changed or fields.keys().any(func(f): return local.get(f) != fields[f]):
		Library.update_book(local.id, fields)


## SyncMerge's rule with this app's chapter keys.
static func _extended_chapters(chapters: Array, entries: Array) -> Array:
	return SyncMerge.extended_chapters(chapters, entries)


## SyncMerge's rule with this app's chapter keys.
static func _chapter_id_of(chapter: Dictionary, index: int) -> String:
	return SyncMerge.chapter_id_of(chapter, index, Library.chapter_key)


## SyncMerge's rule with this app's chapter keys.
static func _chapter_ids(chapters: Array) -> Array:
	return SyncMerge.chapter_ids(chapters, Library.chapter_key)


## SyncMerge's rule with this app's chapter keys.
static func _flagged_ids(e: Dictionary) -> Dictionary:
	return SyncMerge.flagged_ids(e, Library.chapter_key)


func _merge_rules(remote: Array) -> void:
	var best := SyncMerge.newest_rules(remote, TextRules.modified)
	if best.is_empty():
		return
	var list := []
	for r in best.get("list", []):
		if r is Dictionary:
			var c: Dictionary = r.duplicate()
			var book := str(c.get("book", ""))
			if book.begins_with("sync:"):
				var local := Library.find_by_sync_key(book.trim_prefix("sync:"))
				if not local.is_empty():
					c.book = local.id
			list.append(c)
	TextRules.apply_synced(list, SyncMerge.num(best.get("modified", 0)))


func _merge_settings(remote: Array) -> void:
	var best := SyncMerge.winning_settings(remote, Settings.stamps)
	for k in best:
		var v: Variant = best[k].get("v")
		if typeof(v) == TYPE_FLOAT and typeof(Settings.DEFAULTS.get(k)) == TYPE_INT:
			v = int(v)
		Settings.apply_synced(k, v, SyncMerge.num(best[k].get("t", 0)))


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
		"missing": _missing_doc(),
	}


## Book key -> [chapter ids] for index.json's `missing` (see _take_requests).
func _missing_doc() -> Dictionary:
	var out := {}
	for id in _cache.missing:
		var b := Library.get_book(id)
		if not b.is_empty():
			out[Library.sync_key(b)] = _cache.missing[id]
	return out


## A book's file in devices/<id>/books/: everything but what's in its index entry.
## `flags`: from _flags.
func _book_file(b: Dictionary, flags: String) -> Dictionary:
	var out := {
		"key": Library.sync_key(b), "title": b.title, "author": b.author, "kind": b.kind, "source": b.source,
		"url": b.url, "cover_url": b.cover_url, "synopsis": b.synopsis, "tags": b.tags, "tags_set": b.get("tags_set", false), "extra": b.get("extra", {}),
		"rss_only": b.get("rss_only", false), "added": b.added, "last_checked": b.last_checked,
		"last_full_check": b.get("last_full_check", 0), "possible_gap": b.get("possible_gap", false),
		"chapters": SyncMerge.clean_chapters(b.chapters),
		"cover": _cover_names.get(b.id, ""), "cover_set": b.get("cover_set", 0), "on_server": flags,
		"bookmarks": b.get("bookmarks", []).map(func(m):
			var c: int = m.chapter
			return m.merged({"chapter_id": _chapter_id_of(b.chapters[c], c) if c < b.chapters.size() else ""})),
	}
	if int(b.get("total_words", 0)) > 0:  # only when set, so other books' files stay the same
		out.total_words = int(b.total_words)
	if b.has("dropped"):  # only once ever set, likewise
		out.dropped = bool(b.dropped)
	if b.has("archived"):
		out.archived = bool(b.archived)
	if b.has("favorite"):
		out.favorite = bool(b.favorite)
	if b.get("status_set") is Dictionary and not (b.status_set as Dictionary).is_empty():
		out.status_set = b.status_set
	return out


## True when this device has a chapter of the book with its full text that it
## hasn't seen on the server itself, or lacks one that's known to be there.
## `flagged`: the chapter ids other devices have on the server (see _remote_flags).
func _chapters_differ(b: Dictionary, flagged: Dictionary) -> bool:
	var ids := _chapter_ids_of(b)
	var full := _local_full(b)
	var server: Dictionary = _cache.server.get(b.id, {})
	for i in ids.size():
		var there := server.has(ids[i])
		if full.has(i) != there or (not there and not full.has(i) and flagged.has(ids[i])):
			return true
	return false


## Other devices' `missing`: a chapter of ours they didn't find on the server is
## no longer counted as there, so the next check looks and sends it if it's here.
func _take_requests(remote: Array) -> void:
	for d in remote:
		var m: Variant = d.get("missing")
		if not (m is Dictionary):
			continue
		for key in m:
			var b := Library.find_by_sync_key(str(key))
			if b.is_empty() or not (m[key] is Array) or not _cache.server.has(b.id):
				continue
			for id in m[key]:
				_cache.server[b.id].erase(str(id))


## The book's chapter ids (see _chapter_id_of), worked out again only when its
## chapter list has changed.
func _chapter_ids_of(b: Dictionary) -> Array:
	var c: Dictionary = _ids.get(b.id, {})
	if c.is_empty() or not is_same(c.list, b.chapters) or c.size != b.chapters.size():
		c = {"list": b.chapters, "size": b.chapters.size(), "ids": _chapter_ids(b.chapters)}
		_ids[b.id] = c
	return c.ids


## {chapter index: true} for the book's chapters saved here with their full text.
## Kept until its text_stamp changes, which every save of chapter text does.
func _local_full(b: Dictionary) -> Dictionary:
	var stamp := str(b.get("text_stamp", 0))
	var c: Variant = _cache.local.get(b.id)
	var full := {}
	if c is Dictionary and c.get("stamp") == stamp and c.get("full") is Array:
		for i in c.full:
			full[int(i)] = true
		return full
	var dir := DirAccess.open(Library.book_dir(b.id))
	if dir:
		for f in dir.get_files():
			var i := f.get_basename().to_int() if f.ends_with(".json") and f.get_basename().is_valid_int() else -1
			if i >= 0 and i < b.chapters.size() and Library.has_full_chapter(b.id, i):
				full[i] = true
	_cache.local[b.id] = {"stamp": stamp, "full": full.keys()}
	return full


## A book's on_server for its book file: one bit per chapter of its list, set
## when the chapter is known to be in the book's server folder; base64.
func _flags(b: Dictionary) -> String:
	var server: Dictionary = _cache.server.get(b.id, {})
	if server.is_empty():
		return ""
	var ids := _chapter_ids_of(b)
	var bits := PackedByteArray()
	bits.resize(ceili(ids.size() / 8.0))  # filled with zeros
	for i in ids.size():
		if server.has(ids[i]):
			bits[i >> 3] |= 1 << (i & 7)
	return Marshalls.raw_to_base64(bits)


## Book key -> {chapter id: true}: the chapters the other devices know are on the
## server, from the on_server of their book files.
func _remote_flags(remote: Array) -> Dictionary:
	var out := {}
	for d in remote:
		var info: Variant = d.get("device")
		var dev: String = str(info.get("id", "")) if info is Dictionary else ""
		for e in d.books:
			if not (e is Dictionary and e.get("key") is String and e.get("on_server") is String and e.on_server != ""):
				continue
			var at := "%s|%s" % [dev, e.key]
			var c: Array = _flagged.get(at, [])
			if c.is_empty() or c[0] != e.get("md5", ""):
				c = [e.get("md5", ""), _flagged_ids(e)]
				_flagged[at] = c
			if not out.has(e.key):
				out[e.key] = {}
			out[e.key].merge(c[1])
	return out


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
		if now - float(Library.tombstones[k]) > GC_AFTER and not live.has(k) and folders.has(SyncChapters.folder_name(k)):
			await dav.remove(FOLDER + "books/" + SyncChapters.folder_name(k) + "/")


# --- local state -------------------------------------------------------------

static func _empty_cache() -> Dictionary:
	return {"devices": {}, "server": {}, "local": {}, "covers": {}, "missing": {}}


func _state_path() -> String:
	return Settings.data_dir() + "/sync.json"


func _cache_path() -> String:
	return Settings.data_dir() + "/sync_cache.json"


## Other devices' book files, as last downloaded: sync_devices/<device id>/<hash>.json
func _remote_dir() -> String:
	return Settings.data_dir() + "/sync_devices"


func _remote_path(id: String, key: String) -> String:
	return "%s/%s/%s.json" % [_remote_dir(), id, SyncChapters.folder_name(key)]


static func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for d in dir.get_directories():
		_remove_tree(path.path_join(d))
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(path)


func _load_state() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_state_path())) if FileAccess.file_exists(_state_path()) else null
	_state = parsed if parsed is Dictionary else {}
	if _state.get("device_id", "") == "":
		_state.device_id = "%x%08x" % [int(Time.get_unix_time_from_system()), randi()]
	if _state.get("device_name", "") == "":
		_state.device_name = _default_device_name()
	last_sync = float(_state.get("last_sync", 0))
	var cache: Variant = JSON.parse_string(FileAccess.get_file_as_string(_cache_path())) if FileAccess.file_exists(_cache_path()) else null
	_cache = _empty_cache()
	if cache is Dictionary and cache.get("devices") is Dictionary:
		for part in _cache:
			if cache.get(part) is Dictionary:
				_cache[part] = cache[part]
	else:
		_remove_tree(_remote_dir())
	_save_state()


func _save_state() -> void:
	# Through a temp file: a half-written state would read as a new device id.
	SafeFile.write_text(_state_path(), JSON.stringify(_state, "\t"))


func _save_cache() -> void:
	# Through a temp file, like the state above.
	SafeFile.write_text(_cache_path(), JSON.stringify(_cache))


func _exit_tree() -> void:
	_secret.wait_for_thread()


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
