class_name SyncMerge
extends RefCounted
## The sync conflict rules: which entry wins, with data in and decisions out.
## No autoloads, no network, no file access, so the self-test can check them
## without a server. Sync calls these and applies the answers to
## Library/TextRules/Settings/Plugins. All reads of other devices' data use
## .get() with defaults or is_num(), so a malformed remote value is skipped,
## never a crash (a device doc is first cleaned by sanitize_device_doc).

## Numeric JSON (int or float; JSON has no other number type).
static func is_num(x: Variant) -> bool:
	return x is float or x is int


## A remote number, or `default` when it isn't one.
static func num(x: Variant, default := 0.0) -> float:
	if x is float:
		return x
	if x is int:
		return float(x)
	return default


## A remote whole number, or `default` when it isn't one.
static func to_int(x: Variant, default := 0) -> int:
	if x is int:
		return x
	if x is float:
		return int(x)
	return default


## A device doc with malformed parts removed. -> {doc, dropped}: the cleaned
## doc ({} when its books aren't even a list) and how many entries were cut.
## Book entries need a String key and md5 and numeric modified/last_read; the
## other sections keep only well-typed values. The caller logs `dropped`.
static func sanitize_device_doc(data: Variant) -> Dictionary:
	var out := {"doc": {}, "dropped": 0}
	if not (data is Dictionary):
		return out
	var doc: Dictionary = (data as Dictionary).duplicate()
	if not (doc.get("books") is Array):
		return out
	var books := []
	for e in doc.books:
		if e is Dictionary and e.get("key") is String and e.get("md5") is String \
				and is_num(e.get("modified")) and is_num(e.get("last_read")):
			books.append(e)
	out.dropped += doc.books.size() - books.size()
	doc.books = books
	if not (doc.get("device") is Dictionary):
		doc.device = {}
	var tomb: Variant = doc.get("tombstones", {})
	if tomb is Dictionary:
		var kept := {}
		for k in tomb:
			if is_num(tomb[k]):
				kept[k] = float(tomb[k])
			else:
				out.dropped += 1
		doc.tombstones = kept
	elif doc.has("tombstones"):
		doc.tombstones = {}
		out.dropped += 1
	var rules: Variant = doc.get("rules")
	if not (rules is Dictionary and rules.get("list") is Array and is_num(rules.get("modified"))):
		if doc.has("rules"):
			doc.rules = {}
			out.dropped += 1
	for section in ["settings", "plugins"]:
		var part: Variant = doc.get(section)
		if part is Dictionary:
			var kept_part := {}
			for k in part:
				if part[k] is Dictionary and is_num(part[k].get("t")):
					kept_part[k] = part[k]
				else:
					out.dropped += 1
			doc[section] = kept_part
		elif doc.has(section):
			doc[section] = {}
			out.dropped += 1
	var missing: Variant = doc.get("missing")
	if missing is Dictionary:
		var kept_missing := {}
		for k in missing:
			if missing[k] is Array:
				kept_missing[k] = missing[k]
			else:
				out.dropped += 1
		doc.missing = kept_missing
	elif doc.has("missing"):
		doc.missing = {}
		out.dropped += 1
	out.doc = doc
	return out


## The winning entry by a numeric field (modified, last_read), or {}.
## A tie keeps the first, so every device picks the same one.
static func newest_by(entries: Array, field: String) -> Dictionary:
	var best := {}
	for e in entries:
		if e is Dictionary and is_num(e.get(field)) \
				and (best.is_empty() or num(e.get(field)) > num(best.get(field))):
			best = e
	return best


## Which entries win per book key: the newest by modified (details) and by
## last_read (position), plus every entry for combining lists and bookmarks.
## -> key -> {meta, pos, all}
static func group_by_key(remote: Array) -> Dictionary:
	var out := {}
	for d in remote:
		if not (d is Dictionary):
			continue
		var books: Array = d.get("books", []) if d.get("books", []) is Array else []
		for e in books:
			if not (e is Dictionary and e.get("key") is String):
				continue
			var k := str(e.key)
			if not out.has(k):
				out[k] = {"meta": {}, "pos": {}, "all": []}
			out[k].meta = newest_by([out[k].meta, e], "modified")
			out[k].pos = newest_by([out[k].pos, e], "last_read")
			(out[k].all as Array).append(e)
	return out


## A removed book stays removed unless some device used it after the removal.
static func tombstone_removes(tombstone: float, activity: float) -> bool:
	return tombstone >= activity


## The newest cover pick: one chosen by hand last wins, else the newest entry.
## -> {name, set} or {}.
static func pick_cover(entries: Array) -> Dictionary:
	var best := {}
	for e in entries:
		if e is Dictionary and str(e.get("cover", "")) != "" \
				and (best.is_empty() or cover_newer(e, best)):
			best = e
	if best.is_empty():
		return {}
	return {"name": str(best.get("cover", "")), "set": num(best.get("cover_set", 0))}


## The cover picked by hand last wins, else the one of the newest version.
static func cover_newer(a: Dictionary, b: Dictionary) -> bool:
	var sa := num(a.get("cover_set", 0))
	var sb := num(b.get("cover_set", 0))
	return sa > sb if sa != sb else num(a.get("modified", 0)) > num(b.get("modified", 0))


## The newest reading position, clamped to chapters that exist here, or {}
## when this device already read further. The paragraph is kept as the other
## device left it: this device may not have the chapter's text to check it against.
static func newer_progress(local: Dictionary, entry: Dictionary, key_of: Callable) -> Dictionary:
	if num(entry.get("last_read", 0)) <= num(local.get("last_read", 0)):
		return {}
	var prog: Dictionary = entry.get("progress", {}) if entry.get("progress", {}) is Dictionary else {}
	var chapters: Array = local.get("chapters", []) if local.get("chapters", []) is Array else []
	var idx := chapter_index_by_id(chapters, str(prog.get("id", "")), key_of)
	if idx < 0:
		idx = clampi(to_int(prog.get("chapter", 0)), 0, maxi(0, chapters.size() - 1))
	return {"progress": {"chapter": idx, "paragraph": to_int(prog.get("paragraph", 0))},
		"last_read": num(entry.get("last_read", 0))}


## This book's bookmarks plus the other devices' ones: per bookmark, the most
## recently changed version wins (a removal too). Chapters are matched by id, as
## the chapter indexes can differ between devices.
static func merged_bookmarks(local: Dictionary, entries: Array, key_of: Callable) -> Array:
	var source: Array = local.get("bookmarks", []) if local.get("bookmarks", []) is Array else []
	var chapters: Array = local.get("chapters", []) if local.get("chapters", []) is Array else []
	var out: Array = source.duplicate(true)
	var at := {}
	for i in out.size():
		if out[i] is Dictionary and (out[i] as Dictionary).has("id"):
			at[out[i].id] = i
	for e in entries:
		if not (e is Dictionary):
			continue
		var list: Variant = e.get("bookmarks", [])
		if not list is Array:
			continue
		for r in list:
			if not (r is Dictionary and r.has("id")):
				continue
			var i: int = at.get(r.id, -1)
			if i >= 0 and num(r.get("modified", 0)) <= num((out[i] as Dictionary).get("modified", 0)):
				continue
			var ch := chapter_index_by_id(chapters, str(r.get("chapter_id", "")), key_of)
			if ch < 0:
				ch = clampi(to_int(r.get("chapter", 0)), 0, maxi(0, chapters.size() - 1))
			var m := {
				"id": str(r.id), "chapter": ch, "paragraph": to_int(r.get("paragraph", 0)), "name": str(r.get("name", "")),
				"text": str(r.get("text", "")), "created": num(r.get("created", 0)), "modified": num(r.get("modified", 0)),
				"deleted": bool(r.get("deleted", false)),
			}
			if i >= 0:
				out[i] = m
			else:
				at[m.id] = out.size()
				out.append(m)
	return out


## The chapter list an update keeps: combined lists for web books (chapters are
## identified by URL), the longest list starting with this one for imported
## books (their chapters only ever grow at the end).
static func updated_chapters(local_chapters: Array, entry: Dictionary, entries: Array, remote_newer: bool, key_of: Callable) -> Array:
	if has_urls(local_chapters):
		var base: Array = clean_chapters(entry.get("chapters", [])) if remote_newer else local_chapters
		var others: Array = [{"chapters": local_chapters}] + entries if remote_newer else entries
		return combined_chapters(base, others, key_of)
	return extended_chapters(local_chapters, entries)


## The detail fields an update writes: the newest version's fields, or just a
## newer stamp and reading time when this device is newer.
static func detail_fields(local: Dictionary, entry: Dictionary) -> Dictionary:
	var remote_newer := num(entry.get("modified", 0)) > num(local.get("modified", 0))
	var fields := {"modified": maxf(num(entry.get("modified", 0)), num(local.get("modified", 0)))}
	if remote_newer:
		for f in ["title", "author", "synopsis", "tags", "extra", "cover_url", "rss_only", "url", "source", "kind", "total_words", "dropped", "archived", "favorite"]:
			if entry.has(f):
				fields[f] = entry[f]
	else:
		fields["rss_only"] = local.get("rss_only", false)  # replace_chapters clears it
	fields["last_checked"] = maxf(num(local.get("last_checked", 0)), num(entry.get("last_checked", 0)))
	return fields


## Imported books have no chapter URLs, and chapters are only ever added to their
## end: the longest of the other devices' lists that starts with this one, else this one.
static func extended_chapters(chapters: Array, entries: Array) -> Array:
	var best := chapters
	for e in entries:
		if not (e is Dictionary):
			continue
		var list := clean_chapters(e.get("chapters", []))
		if list.size() <= best.size() or (has_urls(list) and not chapters.is_empty()):
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
static func combined_chapters(base: Array, entries: Array, key_of: Callable) -> Array:
	var out := base.duplicate()
	if not has_urls(out) and not out.is_empty():
		return out
	var pos := {}
	for i in out.size():
		pos[chapter_id_of(out[i], i, key_of)] = i
	for e in entries:
		if not (e is Dictionary):
			continue
		var prev := ""
		var list := clean_chapters(e.get("chapters", []))
		for i in list.size():
			var id := chapter_id_of(list[i], i, key_of)
			if not pos.has(id):
				var at: int = pos[prev] + 1 if pos.has(prev) else out.size()
				out.insert(at, list[i])
				pos.clear()
				for j in out.size():
					pos[chapter_id_of(out[j], j, key_of)] = j
			prev = id
	return out


## Only well-formed chapter rows; anything else never took part in a merge.
static func clean_chapters(list: Variant) -> Array:
	var out := []
	if not list is Array:
		return out
	for c in list:
		if c is Dictionary:
			out.append({"title": str(c.get("title", "")), "url": str(c.get("url", "")), "date": c.get("date", 0)})
	return out


static func has_urls(chapters: Array) -> bool:
	return chapters.any(func(c): return c is Dictionary and c.get("url", "") != "")


static func chapter_ids(chapters: Array, key_of: Callable) -> Array:
	var out := []
	for i in chapters.size():
		if chapters[i] is Dictionary:
			out.append(chapter_id_of(chapters[i], i, key_of))
	return out


## Chapters with a URL are identified by it (indexes shift when a chapter list is
## completed); imported books have no URLs and only get chapters added at the end,
## so they use the index.
static func chapter_id_of(chapter: Dictionary, index: int, key_of: Callable) -> String:
	var url := str(chapter.get("url", ""))
	if url == "":
		return "n%d" % index
	return str(key_of.call(url)).md5_text().left(16)


static func chapter_index_by_id(chapters: Array, id: String, key_of: Callable) -> int:
	if id == "":
		return -1
	for i in chapters.size():
		if chapters[i] is Dictionary and chapter_id_of(chapters[i], i, key_of) == id:
			return i
	return -1


## This device's reads, for deciding whether a removal still stands.
static func activity_of(book: Dictionary) -> float:
	return maxf(maxf(num(book.get("modified", 0)), num(book.get("last_read", 0))), num(book.get("added", 0)))


## The rule list that wins: the most recently changed one, or {} to keep ours.
static func newest_rules(remote: Array, current_stamp: float) -> Dictionary:
	var best := {}
	var stamp := current_stamp
	for d in remote:
		if not (d is Dictionary):
			continue
		var r: Variant = d.get("rules")
		if r is Dictionary and r.get("list") is Array and is_num(r.get("modified")) \
				and num(r.get("modified")) > stamp:
			best = r
			stamp = num(r.get("modified"))
	return best


## Per setting, the value changed most recently on any device (stamps: ours).
static func winning_settings(remote: Array, stamps: Dictionary) -> Dictionary:
	var best := {}
	for d in remote:
		if not (d is Dictionary):
			continue
		var s: Variant = d.get("settings")
		if not (s is Dictionary):
			continue
		for k in s:
			if s[k] is Dictionary and is_num(s[k].get("t")) and num(s[k].get("t")) > num(stamps.get(k, 0)) \
					and (not best.has(k) or num(s[k].get("t")) > num(best[k].get("t", 0))):
				best[k] = s[k]
	return best


## Per plugin, the most recent install, update or removal any device saw.
static func newest_plugin_records(remote: Array) -> Dictionary:
	var newest := {}
	for d in remote:
		if not (d is Dictionary):
			continue
		var pl: Variant = d.get("plugins")
		if not (pl is Dictionary):
			continue
		for id in pl:
			if pl[id] is Dictionary and is_num(pl[id].get("t")) \
					and (not newest.has(id) or num(pl[id].get("t")) > num(newest[id].get("t", 0))):
				newest[id] = pl[id]
	return newest


## The ids of the chapters set in a book file's on_server.
static func flagged_ids(entry: Dictionary, key_of: Callable) -> Dictionary:
	var bits := Marshalls.base64_to_raw(str(entry.get("on_server", "")))
	var list: Variant = entry.get("chapters", [])
	var out := {}
	if not list is Array:
		return out
	for i in mini(list.size(), bits.size() * 8):
		if bits[i >> 3] & (1 << (i & 7)) and list[i] is Dictionary:
			out[chapter_id_of(list[i], i, key_of)] = true
	return out


## Sums up what decides whether a book's cover needs syncing: its cover here,
## the cover wanted, and whether its server folder exists.
static func cover_sig(b: Dictionary, on_server: bool, wanted: Dictionary) -> String:
	return "%s|%s|%s|%s|%s" % [b.get("cover", ""), b.get("cover_set", 0), wanted.get("name", ""), wanted.get("set", 0), on_server]


## A book's entry in index.json: what changes often, and the md5 of its book file.
static func index_entry(b: Dictionary, key: String, md5: String, key_of: Callable) -> Dictionary:
	var p: Dictionary = b.progress
	var at: int = p.chapter
	var chapters: Array = b.chapters
	return {
		"key": key, "md5": md5, "modified": b.modified, "last_read": b.last_read, "texts": b.get("text_stamp", 0),
		"progress": {"id": chapter_id_of(chapters[at], at, key_of) if at < chapters.size() else "", "chapter": at, "paragraph": p.paragraph},
	}


## True when the version folder holds the manifest: files go up first and the
## manifest last, so a version without it was never uploaded completely.
static func version_complete(entries: Array, manifest: String) -> bool:
	for e in entries:
		if e is Dictionary and str(e.get("name", "")) == manifest and not bool(e.get("is_dir", false)):
			return true
	return false
