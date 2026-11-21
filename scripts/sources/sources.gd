extends Node
## Routes searches, new books and chapter downloads to the site plugins (see
## Plugins). A book's `source` is the id of the plugin that fetches it, or
## "web" for pages saved in the Web tab, or "file" for imported books.
##
## Work the user is waiting for (opening a chapter, a search, adding a book) goes
## first: background work (reading ahead, update checks) for the same plugin waits
## until it's done before starting its next step. Net paces the requests themselves.

## A book whose last full chapter list is this old gets a full check again: a
## short quick list may have missed chapters in between.
const FULL_CHECK_DAYS := 7

var _user_jobs := {}  # plugin id -> jobs the user is waiting for, running now


## Runs `job` as work the user is waiting for, so background work on the same plugin holds off.
func _for_user(plugin_id: String, job: Callable) -> Variant:
	_user_jobs[plugin_id] = int(_user_jobs.get(plugin_id, 0)) + 1
	var r: Variant = await job.call()
	_user_jobs[plugin_id] -= 1
	return r


## Background work calls this before each step: it waits while the user is waiting on the same plugin.
func wait_for_user(plugin_id: String) -> void:
	while int(_user_jobs.get(plugin_id, 0)) > 0:
		await get_tree().process_frame


func _run(plugin_id: String, background: bool, job: Callable) -> Variant:
	if background:
		await wait_for_user(plugin_id)
		return await job.call()
	return await _for_user(plugin_id, job)


# --- plugin data -------------------------------------------------------------

## One chapter as the app stores it: {title, url, date, excerpt_html?}. {} when
## the plugin's item has no link to download, so callers can drop it.
static func norm_chapter(c: Variant) -> Dictionary:
	if not (c is Dictionary):
		return {}
	if str(c.get("url", "")) == "":
		return {}
	var d: Variant = c.get("date", 0)
	var out := {"title": str(c.get("title", "")), "url": str(c.url),
		"date": int(d) if d is int or d is float else 0}
	var excerpt: Variant = c.get("excerpt_html", "")
	if excerpt is String and excerpt != "":
		out.excerpt_html = excerpt
	return out


## A whole fetch_novel result: {novel} with safe defaults, or {error} naming the
## plugin when nothing usable came back. `url_fallback` fills in a book link the
## plugin left out.
static func norm_novel(n: Variant, plugin_name: String, url_fallback := "") -> Dictionary:
	if not (n is Dictionary):
		return {"error": "%s returned a book without details." % plugin_name}
	var chapters := []
	var raw: Variant = n.get("chapters", [])
	if raw is Array:
		for c in raw:
			var nc := norm_chapter(c)
			if not nc.is_empty():
				chapters.append(nc)
	if str(n.get("title", "")) == "":
		return {"error": "%s returned a book without a title." % plugin_name}
	if chapters.is_empty():
		return {"error": "%s returned a book without chapters." % plugin_name}
	var tags: Variant = n.get("tags", [])
	var extra: Variant = n.get("extra", null)
	var words: Variant = n.get("words", 0)
	var out := {"title": str(n.title), "author": str(n.get("author", "")),
		"cover_url": str(n.get("cover_url", "")), "synopsis": str(n.get("synopsis", "")),
		"tags": tags if tags is Array else [],
		"url": str(n.get("url", url_fallback)) if str(n.get("url", url_fallback)) != "" else url_fallback,
		"chapters": chapters, "words": int(words) if words is int or words is float else 0}
	if extra is Dictionary:
		out.extra = extra
	return {"novel": out}


## A quick update check result: {chapters}, {} when there's nothing usable (so
## the caller does a full check instead), or {error, blocked} for a bot check.
## One chapter without a link poisons the whole list: dropping it could hide a
## gap in the middle.
static func norm_latest(r: Variant, plugin_name: String) -> Dictionary:
	if not (r is Dictionary):
		return {}
	if r.is_empty():
		return {}
	if bool(r.get("blocked", false)):
		var e := str(r.get("error", ""))
		return {"error": e if e != "" else "%s is showing a bot check to the app." % plugin_name, "blocked": true}
	if str(r.get("error", "")) != "":
		return {}
	var raw: Variant = r.get("chapters", null)
	if not (raw is Array) or raw.is_empty():
		return {}
	var chapters := []
	for c in raw:
		var nc := norm_chapter(c)
		if nc.is_empty():
			return {}
		chapters.append(nc)
	return {"chapters": chapters}


## A whole search result: {results, error, blocked}, dropping items without a
## link. An empty list stays one: finding nothing is a valid answer.
static func norm_search(res: Variant, plugin_name: String) -> Dictionary:
	if not (res is Dictionary):
		return {"results": [], "error": "%s returned a broken search response." % plugin_name}
	var out := {"results": [], "error": str(res.get("error", "")), "blocked": bool(res.get("blocked", false))}
	var raw: Variant = res.get("results", [])
	if raw is Array:
		for x in raw:
			if x is Dictionary and str(x.get("url", "")) != "":
				out.results.append({"title": str(x.get("title", "")), "url": str(x.url),
					"cover_url": str(x.get("cover_url", "")), "info": str(x.get("info", ""))})
	if res.has("web_url"):
		out.web_url = str(res.web_url)
	return out


## A whole fetch_chapter result: {title, paragraphs, error}, with paragraphs as
## an array of non-empty strings. Emptiness stays the caller's call.
static func norm_chapter_text(r: Variant, plugin_name: String) -> Dictionary:
	if not (r is Dictionary):
		return {"title": "", "paragraphs": PackedStringArray(), "error": "%s returned a broken chapter." % plugin_name}
	var paras := PackedStringArray()
	var raw: Variant = r.get("paragraphs", [])
	if raw is String:
		raw = [raw]
	if raw is Array or raw is PackedStringArray:
		for p in raw:
			if p is String and p.strip_edges() != "":
				paras.append(p)
	return {"title": str(r.get("title", "")), "paragraphs": paras, "error": str(r.get("error", ""))}


# --- discovery ---------------------------------------------------------------

## Every source Browse can search: [{key, label, disabled}], key is "<plugin id>|<plugin's own key>".
func search_choices() -> Array:
	var out := []
	for p in Plugins.plugins:
		for s in await p.search_sources():
			out.append({"key": p.id + "|" + str(s.get("key", "")), "label": str(s.get("label", p.name)), "disabled": s.get("disabled", false)})
	return out


## `choice` is a key from search_choices(). -> {results, error, blocked, web_url}
func search(query: String, choice: String) -> Dictionary:
	var p := Plugins.get_plugin(choice.get_slice("|", 0))
	if p == null:
		return {"results": [], "error": "That source's plugin isn't installed or is switched off."}
	var raw: Variant = await _for_user(p.id, func(): return await p.search(query, choice.substr(choice.find("|") + 1)))
	var r := norm_search(raw, p.name)
	for x in r.results:
		x.source = p.id
	if r.get("blocked", false) and p.search_url(query) != "":
		r.web_url = p.search_url(query)
	return r


## Add a web novel by URL. Returns the book or {"error": msg, "web_url": url to open in the Web tab}.
func add_from_url(url: String) -> Dictionary:
	url = url.strip_edges()
	if not url.begins_with("http"):
		return {"error": "Please paste a full link starting with http(s)://"}
	var existing := Library.find_by_url(url)
	if not existing.is_empty():
		return existing
	var p := Plugins.for_url(url)
	if p == null:
		return {"error": "None of your plugins handles this site. Open the page in the Web tab instead: Add to library there works on any site.", "web_url": url}
	var source := p.id
	var res: Variant = await _for_user(p.id, func(): return await p.fetch_novel(url))
	if res is Dictionary and bool(res.get("blocked", false)):
		res.web_url = url
	if res is Dictionary and str(res.get("error", "")) != "":
		return res
	var checked := norm_novel(res.get("novel", {}) if res is Dictionary else {}, p.name, url)
	if checked.has("error"):
		checked.web_url = url
		return checked
	var n: Dictionary = checked.novel
	var now := Time.get_unix_time_from_system()
	var book := Library.add_book({
		"title": n.title, "author": n.get("author", ""), "kind": "web", "source": source,
		"url": n.get("url", url), "cover_url": n.get("cover_url", ""), "synopsis": n.get("synopsis", ""),
		"tags": n.get("tags", []), "extra": n.get("extra", {}), "rss_only": res.get("rss_only", false),
		"total_words": int(n.get("words", 0)),
		"chapters": n.chapters.map(func(c): return {"title": c.title, "url": c.url, "date": c.date}),
		"last_checked": now,
		# Adding reads the full list, so it counts as a full check, unless the
		# plugin fell back to its short list.
		"last_full_check": 0 if bool(res.get("rss_only", false)) else now,
	})
	_store_excerpts(book, n.chapters, 0)
	fetch_cover(book)
	return book


# --- reading -----------------------------------------------------------------

## -> {title, paragraphs, excerpt, error}. `background`: reading ahead, nobody is waiting for it.
## Asking for a chapter that's already downloading waits for that download.
func load_chapter(book: Dictionary, index: int, background := false) -> Dictionary:
	var cached := Library.load_chapter(book.id, index)
	if not cached.is_empty() and not cached.get("excerpt", false):
		return cached
	if book.kind != "web":
		return {"error": "Chapter %d is missing from this book." % (index + 1)}
	var ch: Dictionary = book.chapters[index]
	if Library.is_epub_only(ch):
		return {"error": "This chapter came from an EPUB and isn't on the site any more. Add the EPUB to this book again to get it back."}
	if book.source == "web":
		if not cached.is_empty():
			return cached
		return {"error": "This chapter hasn't been saved yet. Open it in the Web tab to read or listen to it."}
	var p := Plugins.get_plugin(book.source)
	if p == null:
		if not cached.is_empty():
			return cached
		return {"error": missing_plugin_message(book)}
	var raw: Variant = await Net.shared("chapter\n%s\n%d" % [book.id, index], func():
		return await _run(p.id, background, func(): return await p.fetch_chapter(book, ch, index)))
	var r := norm_chapter_text(raw, p.name)
	if r.get("error", "") == "" and r.get("paragraphs", []).size() > 0:
		Library.store_chapter(book.id, index, ch.title, r.paragraphs)
		return {"title": ch.title, "paragraphs": r.paragraphs, "excerpt": false}
	if not cached.is_empty():  # an RSS preview is better than nothing
		return cached
	if r.get("error", "") == "blocked":
		return {"error": p.blocked_message()}
	return {"error": r.get("error", "Empty chapter")}


## Re-check a web book for new chapters. -> {new: int, error}. `background`: an update
## check nobody is waiting on. `full`: read the book's whole chapter list even when a
## quick check would do (the reader asked for it). A check of a book that's already
## being checked the same way waits for it.
func refresh(book: Dictionary, background := false, full := false) -> Dictionary:
	if book.kind != "web" or book.source == "web":
		return {"new": 0, "error": ""}
	var p := Plugins.get_plugin(book.source)
	if p == null:
		return {"new": 0, "error": missing_plugin_message(book)}
	# A full check mustn't be handed a quick check's result that's already running.
	return await Net.shared(("refresh-full\n" if full else "refresh\n") + str(book.id),
		func(): return await _refresh(p, book, background, full))


## True when the next update check must read the book's full chapter list: new
## books, books never fully checked, and books whose last full check is
## FULL_CHECK_DAYS old or more.
static func full_check_due(book: Dictionary, now: float) -> bool:
	if (book.get("chapters", []) as Array).is_empty():
		return true
	var last := float(book.get("last_full_check", 0))
	if last <= 0:
		return true
	return now - last >= float(FULL_CHECK_DAYS) * 86400.0


## Whether the quick list's oldest chapter is already in the book, so nothing
## between the book and the quick list was missed.
static func reaches_back(book: Dictionary, chapters: Array) -> bool:
	if chapters.is_empty() or not (chapters[0] is Dictionary):
		return false
	var first := Library.chapter_key(str(chapters[0].get("url", "")))
	for c in book.get("chapters", []):
		if Library.chapter_key(str(c.get("url", ""))) == first:
			return true
	return false


## Merge `chapters` into the book (unknown ones appended, missing dates filled
## in, previews stored) and save it with `fields` plus the new list. Only a
## full check passes extra/total_words/last_full_check/possible_gap in fields;
## a quick check passes {} so those stay untouched.
func _merge(book: Dictionary, chapters: Array, fields: Dictionary) -> Dictionary:
	var known := {}
	for c in book.chapters:
		known[Library.chapter_key(c.url)] = c
	var added := 0
	var first_new: int = book.chapters.size()
	for c in chapters:
		var old: Variant = known.get(Library.chapter_key(c.url))
		if old == null:
			book.chapters.append({"title": c.title, "url": c.url, "date": c.get("date", 0)})
			added += 1
		elif float(old.get("date", 0)) <= 0 and float(c.get("date", 0)) > 0:
			old.date = c.date  # fill in dates an older plugin version didn't report
	_store_excerpts(book, chapters, 0)
	fields["last_checked"] = Time.get_unix_time_from_system()
	fields["chapters"] = book.chapters
	Library.update_book(book.id, fields)
	return {"new": added, "error": "", "first_new": first_new}


## A full update check: read the whole chapter list and merge it. A short
## rss_only fallback list isn't a full list: it leaves last_full_check alone
## and flags a gap it can't fill.
func _full_check(p: SourcePlugin, book: Dictionary, background: bool, now: float) -> Dictionary:
	var res: Variant = await _run(p.id, background, func(): return await p.fetch_novel(book.url))
	if res is Dictionary and str(res.get("error", "")) != "":
		return {"new": 0, "error": str(res.error)}
	var checked := norm_novel(res.get("novel", {}) if res is Dictionary else {}, p.name, book.url)
	if checked.has("error"):
		return {"new": 0, "error": checked.error}
	var novel: Dictionary = checked.novel
	var fields := {}
	if novel.has("extra"):
		fields.extra = novel.extra
	if int(novel.get("words", 0)) > 0:
		fields.total_words = int(novel.words)
	if bool(res.get("rss_only", false)):
		if not book.chapters.is_empty() and not reaches_back(book, novel.chapters):
			fields.possible_gap = true
		return _merge(book, novel.chapters, fields)
	fields.last_full_check = now
	fields.possible_gap = false
	return _merge(book, novel.chapters, fields)


func _refresh(p: SourcePlugin, book: Dictionary, background: bool, force_full := false) -> Dictionary:
	var now := Time.get_unix_time_from_system()
	if force_full or full_check_due(book, now):
		return await _full_check(p, book, background, now)
	var quick: Variant = await _run(p.id, background, func(): return await p.fetch_latest(book.url))
	var q := norm_latest(quick, p.name)
	if q.has("error"):
		# Blocked: the fetch queue already backs off this site, and the full
		# page would be blocked too, so don't try it.
		return {"new": 0, "error": str(q.error)}
	if q.is_empty():
		return await _full_check(p, book, background, now)
	var chapters: Array = q.chapters
	if reaches_back(book, chapters):
		return _merge(book, chapters, {})
	var full := await _full_check(p, book, background, now)
	if str(full.get("error", "")) != "":
		# A gap was found but no full list could be fetched: flag it, and keep
		# the quick chapters so the reader still gets the new ones.
		_merge(book, chapters, {"possible_gap": true})
	return full


func missing_plugin_message(book: Dictionary) -> String:
	var e := Plugins.get_entry(book.source)
	if not e.is_empty():
		return "The %s plugin is switched off or can't run here%s. Turn it on in Settings → Plugins, or open the chapter in the Web tab." % [e.name, (": " + e.error) if e.error != "" else ""]
	return "This book comes from a plugin that isn't installed (%s). Install it in Settings → Plugins, or open the chapter in the Web tab." % book.source


func _store_excerpts(book: Dictionary, chapters: Array, _offset: int) -> void:
	var index_of := {}
	for i in book.chapters.size():
		index_of[book.chapters[i].url] = i
	for c in chapters:
		if c.has("excerpt_html") and index_of.has(c.url) and not Library.has_chapter(book.id, index_of[c.url]):
			Library.store_chapter(book.id, index_of[c.url], c.title, HtmlText.to_paragraphs(c.excerpt_html), true)


func fetch_cover(book: Dictionary) -> void:
	if book.cover_url == "":
		return
	var img := await Net.get_image(book.cover_url)
	if img:
		Library.update_book(book.id, {"cover": Library.save_cover(book.id, img)})
