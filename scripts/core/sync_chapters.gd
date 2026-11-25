class_name SyncChapters
extends RefCounted
## The chapter part of the library sync: sends and fetches the chapters of books,
## packs many small chapters into one file, and works out which chapters each side
## is missing. Sync keeps the connection, the progress line and the state; this
## helper calls back into it for those.

# Untyped on purpose: the owner is the Sync autoload, which has no class_name, and
# its private methods would fail a typed check at compile time.
var _owner


func _init(owner_node: Node) -> void:
	_owner = owner_node


static func folder_name(key: String) -> String:
	return key.md5_text().left(20)


## `flagged`: the chapter ids other devices say are in the book's folder.
func sync_book(dav: WebDav, pool: Array[WebDav], b: Dictionary, folders: Dictionary, wanted: Dictionary, flagged: Dictionary, label := "") -> String:
	var key := Library.sync_key(b)
	var folder := Sync.FOLDER + "books/" + folder_name(key) + "/"
	var exists := folders.has(folder_name(key))
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
	var done: Dictionary = _owner._done.get(b.id, {})
	_owner._done[b.id] = done
	var packs := {}    # pack file name -> [chapter file names in it]
	var in_pack := {}  # chapter file name -> the pack it's in
	var err := await _read_packs(pool, folder, remote, packs)
	if err != "":
		return err
	for p in packs:
		for name in packs[p]:
			in_pack[name] = p
	var server := {}  # chapter ids in the folder, as listed
	for n in remote:
		if n.ends_with(".json") and not n.begins_with("pack-") and int(remote[n]) > 0:
			server[n.get_basename()] = true
	for name in in_pack:
		server[name.get_basename()] = true
	_owner._cache.server[b.id] = server

	# work out what to send and fetch, then do it over several connections
	var downs := []  # chapter file names
	var ups := []    # [chapter file name, index]
	var loose := []  # [chapter file name, index]: on the server only as its own file, and here
	for i in b.chapters.size():
		var name := Sync._chapter_id_of(b.chapters[i], i) + ".json"
		var on_server := remote.has(name) or in_pack.has(name)
		var local_full := Library.has_full_chapter(b.id, i)
		if remote.has(name) and int(remote[name]) > 0 and not in_pack.has(name) and local_full:
			loose.append([name, i])
		if on_server and done.has(name):
			continue
		if on_server and not local_full:
			downs.append(name)
		elif local_full and not in_pack.has(name) and (not remote.has(name) or int(remote[name]) == 0):
			ups.append([name, i])
		elif on_server and local_full:
			done[name] = true
	# many chapters with only their own files (sent one by one, e.g. by an older
	# version): pack them too, so a new device fetches them in few requests
	if loose.size() >= Sync.PACK_MIN:
		ups.append_array(loose)
	var jobs := _chapter_jobs(b, downs, ups, remote, packs, in_pack)
	if not exists and jobs.any(func(j): return j.kind in ["put", "put_pack"]):
		var m := await dav.make_dir(folder)
		if not m.ok:
			return m.error
		exists = true
	if not jobs.is_empty():
		var total := 0
		for j in jobs:
			total += int(j.count)
		var work := {"jobs": jobs, "next": 0, "finished": 0, "total": total, "running": pool.size(), "error": "",
			"book": b, "folder": folder, "done": done, "label": label, "index": {}, "chapters": null}
		for d in pool:
			_chapter_worker(d, work)
		while work.running > 0:
			await _owner.get_tree().process_frame
		for name in done:  # sent or fetched (also when a job failed after others)
			server[name.get_basename()] = true
		if work.error != "":
			return work.error
		if Library.get_book(b.id).is_empty():
			return ""
	var missing := []  # said to be there, but aren't
	for id in _owner._chapter_ids_of(b):
		if flagged.has(id) and not server.has(id):
			missing.append(id)
	if missing.is_empty():
		_owner._cache.missing.erase(b.id)
	else:
		_owner._cache.missing[b.id] = missing

	var cover: String = wanted.get("name", "")
	if cover != "" and not SyncPlugins.safe_name(cover):
		print("Sync: book %s: skipped an unsafe cover name" % Library.sync_key(b))
		cover = ""
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
		_owner._cover_names[b.id] = name
	elif cover != "" and remote.has(cover):
		var g := await dav.fetch(folder + cover)
		if g.ok and Image.new().load_png_from_buffer(g.body) == OK and not Library.get_book(b.id).is_empty():
			DirAccess.make_dir_recursive_absolute(Settings.data_dir() + "/covers")
			var path := "%s/covers/%s.png" % [Settings.data_dir(), b.id]
			if SafeFile.write_bytes(path, g.body):
				_owner._applying = true
				Library.update_book(b.id, {"cover": path, "cover_set": float(wanted.get("set", 0)), "modified": b.modified})
				_owner._applying = false
				_owner._cover_names[b.id] = cover
	return ""


## Takes chapter jobs from `work` until none are left or one fails (work.error).
## Several of these run at once, each on its own connection.
func _chapter_worker(dav: WebDav, work: Dictionary) -> void:
	var b: Dictionary = work.book
	var jobs: Array = work.jobs
	while work.error == "" and work.next < jobs.size() and not Library.get_book(b.id).is_empty():
		var job: Dictionary = jobs[work.next]
		work.next += 1
		var r: Dictionary
		match job.kind:
			"put":
				var at := _job_index(work, job.name.get_basename())
				if at < 0:
					continue
				r = await dav.put(work.folder + job.name, FileAccess.get_file_as_bytes("%s/%d.json" % [Library.book_dir(b.id), at]), "application/json")
				if r.ok:
					work.done[job.name] = true
			"get":
				r = await dav.fetch(work.folder + job.name)
				if r.ok and not Library.get_book(b.id).is_empty():
					var ch: Variant = JSON.parse_string(r.body.get_string_from_utf8())
					# the chapter list may have changed while downloading; find the chapter again
					var at := _job_index(work, job.name.get_basename())
					if ch is Dictionary and ch.get("paragraphs") is Array and at >= 0:
						Library.store_chapter(b.id, at, str(ch.get("title", b.chapters[at].title)), PackedStringArray(ch.paragraphs))
						work.done[job.name] = true
			"put_pack":
				r = await _put_pack(dav, work, job.names)
			"get_pack":
				r = await _get_pack(dav, work, job.name)
		if not r.ok:
			work.error = r.error
			break
		work.finished += int(job.count)
		# shown at most a few times a second; a big book can take many minutes
		if work.label != "" and Time.get_ticks_msec() - _owner._progress_shown > 250:
			_owner._progress_shown = Time.get_ticks_msec()
			_owner._set_progress("%s, %d of %d chapters…" % [work.label, mini(work.finished, work.total), work.total])
	work.running -= 1


## The jobs for _chapter_worker: {kind, count (chapters it covers), name or names}.
## Many chapters to send go in packs; a pack is fetched instead of its chapters'
## own files when it's the only copy of one, or when a good part of it is wanted.
static func _chapter_jobs(b: Dictionary, downs: Array, ups: Array, remote: Dictionary, packs: Dictionary, in_pack: Dictionary) -> Array:
	var jobs := []
	var wanted := {}  # pack -> chapters wanted from it
	var only := {}    # pack -> true: holds a wanted chapter that has no file of its own
	for name in downs:
		if in_pack.has(name):
			var p: String = in_pack[name]
			wanted[p] = wanted.get(p, 0) + 1
			if not remote.has(name):
				only[p] = true
	var from_pack := {}
	for p in wanted:
		if only.has(p) or wanted[p] * 4 >= packs[p].size():
			jobs.append({"kind": "get_pack", "name": p, "count": wanted[p]})
			for name in packs[p]:
				from_pack[name] = true
	for name in downs:
		if not from_pack.has(name):
			jobs.append({"kind": "get", "name": name, "count": 1})
	if ups.size() < Sync.PACK_MIN:
		for u in ups:
			jobs.append({"kind": "put", "name": u[0], "count": 1})
		return jobs
	var names := []
	var bytes := 0
	for u in ups:
		var f := FileAccess.open("%s/%d.json" % [Library.book_dir(b.id), u[1]], FileAccess.READ)
		var size := f.get_length() if f else 0
		if size > Sync.PACK_BYTES:  # on its own, so no pack can unpack past Sync.PACK_GZIP_MAX
			jobs.append({"kind": "put", "name": u[0], "count": 1})
			continue
		if not names.is_empty() and bytes + size > Sync.PACK_BYTES:
			jobs.append({"kind": "put_pack", "names": names, "count": names.size()})
			names = []
			bytes = 0
		names.append(u[0])
		bytes += size
	if not names.is_empty():
		jobs.append({"kind": "put_pack", "names": names, "count": names.size()})
	return jobs


## Fills `packs` (pack file name -> [chapter file names]) from the complete packs
## in a book's server folder, whose listing is `remote`. -> error or "".
func _read_packs(pool: Array[WebDav], folder: String, remote: Dictionary, packs: Dictionary) -> String:
	var fetch := []
	for n in remote:
		if n.begins_with("pack-") and n.ends_with(".ids.json") and remote.has(n.trim_suffix(".ids.json") + ".json.gz"):
			if not _owner._pack_ids.has(folder + n):
				fetch.append(n)
	if not fetch.is_empty():
		var err: String = await _owner._in_parallel(pool, fetch, func(dav: WebDav, n: String) -> String:
			var g := await dav.fetch(folder + n)
			if g.code == 404:
				return ""
			if not g.ok:
				return g.error
			var ids: Variant = JSON.parse_string(g.body.get_string_from_utf8())
			_owner._pack_ids[folder + n] = ids if ids is Array else []
			return "")
		if err != "":
			return err
	for n in remote:
		if _owner._pack_ids.has(folder + n) and remote.has(n.trim_suffix(".ids.json") + ".json.gz"):
			packs[n.trim_suffix(".ids.json") + ".json.gz"] = _owner._pack_ids[folder + n].map(func(id): return str(id) + ".json")
	return ""


## Sends chapters (file names) of work.book as one pack, then its list of ids.
func _put_pack(dav: WebDav, work: Dictionary, names: Array) -> Dictionary:
	var b: Dictionary = work.book
	var chapters := {}
	for name in names:
		var at := _job_index(work, name.get_basename())
		if at < 0:
			continue
		var ch: Variant = JSON.parse_string(FileAccess.get_file_as_string("%s/%d.json" % [Library.book_dir(b.id), at]))
		if ch is Dictionary and ch.get("paragraphs") is Array:
			chapters[name.get_basename()] = {"title": str(ch.get("title", "")), "paragraphs": ch.paragraphs}
	if chapters.is_empty():
		return {"ok": true}
	var text := JSON.stringify({"chapters": chapters})
	var base: String = work.folder + "pack-" + text.md5_text().left(16)
	var r := await dav.put(base + ".json.gz", text.to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP), "application/gzip")
	if not r.ok:
		return r
	var ids := chapters.keys()
	r = await dav.put(base + ".ids.json", JSON.stringify(ids).to_utf8_buffer(), "application/json")  # last: marks it complete
	if r.ok:
		_owner._pack_ids[base + ".ids.json"] = ids
		for id in ids:
			work.done[id + ".json"] = true
	return r


## Fetches a pack and saves the chapters in it this device doesn't have yet.
func _get_pack(dav: WebDav, work: Dictionary, name: String) -> Dictionary:
	var b: Dictionary = work.book
	var r := await dav.fetch(work.folder + name)
	if not r.ok or Library.get_book(b.id).is_empty():
		return r
	var raw: PackedByteArray = r.body.decompress_dynamic(Sync.PACK_GZIP_MAX, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		return r  # damaged, or unpacks past Sync.PACK_GZIP_MAX: fetched one by one next time, if they have their own files
	var data: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not (data is Dictionary and data.get("chapters") is Dictionary):
		return r  # damaged: its chapters are fetched one by one next time, if they have their own files
	var saved := 0
	for id in data.chapters:
		var ch: Variant = data.chapters[id]
		var at := _job_index(work, str(id))
		if at < 0 or not (ch is Dictionary and ch.get("paragraphs") is Array):
			continue
		if not Library.has_full_chapter(b.id, at):
			Library.store_chapter(b.id, at, str(ch.get("title", b.chapters[at].title)), PackedStringArray(ch.paragraphs))
			saved += 1
			if saved % 20 == 0:  # counting words takes a while; keep the app responsive
				await _owner.get_tree().process_frame
				if Library.get_book(b.id).is_empty():
					return r
		work.done[str(id) + ".json"] = true
	return r


## A chapter's current index by its id, from a map that's rebuilt only when the
## book's chapter list has changed (looking each one up anew is slow for big books).
func _job_index(work: Dictionary, id: String) -> int:
	var b: Dictionary = work.book
	var at: int = work.index.get(id, -1)
	if work.chapters != null and is_same(work.chapters, b.chapters) and at >= 0 and at < b.chapters.size() \
			and Sync._chapter_id_of(b.chapters[at], at) == id:
		return at
	work.chapters = b.chapters
	work.index = {}
	for i in b.chapters.size():
		work.index[Sync._chapter_id_of(b.chapters[i], i)] = i
	return work.index.get(id, -1)
