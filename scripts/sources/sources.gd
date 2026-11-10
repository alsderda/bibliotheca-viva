extends Node
## Routes searches, new books and chapter downloads to the site plugins (see
## Plugins). A book's `source` is the id of the plugin that fetches it, or
## "web" for pages saved in the Web tab, or "file" for imported books.
##
## Work the user is waiting for (opening a chapter, a search, adding a book) goes
## first: background work (reading ahead, update checks) for the same plugin waits
## until it's done before starting its next step. Net paces the requests themselves.

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
	var r: Dictionary = await _for_user(p.id, func(): return await p.search(query, choice.substr(choice.find("|") + 1)))
	r.merge({"results": [], "error": ""})
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
	var res: Dictionary = await _for_user(p.id, func(): return await p.fetch_novel(url))
	if res.get("blocked", false):
		res.web_url = url
	if res.get("error", "") != "":
		return res
	var n: Dictionary = res.novel
	var book := Library.add_book({
		"title": n.title, "author": n.get("author", ""), "kind": "web", "source": source,
		"url": n.get("url", url), "cover_url": n.get("cover_url", ""), "synopsis": n.get("synopsis", ""),
		"tags": n.get("tags", []), "extra": n.get("extra", {}), "rss_only": res.get("rss_only", false),
		"total_words": int(n.get("words", 0)),
		"chapters": n.chapters.map(func(c): return {"title": c.title, "url": c.url, "date": c.get("date", 0)}),
		"last_checked": Time.get_unix_time_from_system(),
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
	var r: Dictionary = await Net.shared("chapter\n%s\n%d" % [book.id, index], func():
		return await _run(p.id, background, func(): return await p.fetch_chapter(book, ch, index)))
	if r.get("error", "") == "" and r.get("paragraphs", []).size() > 0:
		Library.store_chapter(book.id, index, ch.title, r.paragraphs)
		return {"title": ch.title, "paragraphs": r.paragraphs, "excerpt": false}
	if not cached.is_empty():  # an RSS preview is better than nothing
		return cached
	if r.get("error", "") == "blocked":
		return {"error": p.blocked_message()}
	return {"error": r.get("error", "Empty chapter")}


## Re-check a web book for new chapters. -> {new: int, error}. `background`: an update
## check nobody is waiting on. A check of a book that's already being checked waits for it.
func refresh(book: Dictionary, background := false) -> Dictionary:
	if book.kind != "web" or book.source == "web":
		return {"new": 0, "error": ""}
	var p := Plugins.get_plugin(book.source)
	if p == null:
		return {"new": 0, "error": missing_plugin_message(book)}
	return await Net.shared("refresh\n" + str(book.id), func(): return await _refresh(p, book, background))


func _refresh(p: SourcePlugin, book: Dictionary, background: bool) -> Dictionary:
	var res: Dictionary = await _run(p.id, background, func(): return await p.fetch_novel(book.url))
	if res.get("error", "") != "":
		return {"new": 0, "error": res.error}
	var known := {}
	for c in book.chapters:
		known[Library.chapter_key(c.url)] = c
	var added := 0
	var first_new: int = book.chapters.size()
	for c in res.novel.chapters:
		var old: Variant = known.get(Library.chapter_key(c.url))
		if old == null:
			book.chapters.append({"title": c.title, "url": c.url, "date": c.get("date", 0)})
			added += 1
		elif float(old.get("date", 0)) <= 0 and float(c.get("date", 0)) > 0:
			old.date = c.date  # fill in dates an older plugin version didn't report
	_store_excerpts(book, res.novel.chapters, 0)
	var fields := {"last_checked": Time.get_unix_time_from_system(), "chapters": book.chapters}
	if res.novel.has("extra"):
		fields.extra = res.novel.extra
	if int(res.novel.get("words", 0)) > 0:
		fields.total_words = int(res.novel.words)
	Library.update_book(book.id, fields)
	return {"new": added, "error": "", "first_new": first_new}


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
