extends Node
## Book library, stored in the profile folder:
##   library.json        the list of books with what changes often (reading
##                       position, last_read, text_stamp) and the tombstones
##   meta/<id>.json      the rest of each book; rewritten only when it changes
##   books/<id>/<n>.json chapter text
##   covers/<id>.png
## Writes happen at the end of the frame (see save), so many changes in a row
## write each file once.
##
## Book dictionary:
##   id, title, author, kind ("epub" | "txt" | "web"), source ("file" | "web" | the id of the plugin that fetches it),
##   url, cover (path or ""), cover_set (unix time the cover was picked by hand, else 0), cover_url, synopsis, tags, rss_only, extra (the plugin's own data, see SourcePlugin),
##   total_words (the book's length as the site reports it, 0 if unknown),
##   chapters: [{title, url, date, words}] (words: set once the chapter's full text is saved), progress: {chapter, paragraph}, added, last_read, last_checked,
##   modified (last local change to anything but progress and bookmarks), sync_key (see Sync),
##   text_stamp (unix time chapter text was last saved or moved, see Sync),
##   dropped (true: the reader gave up on it; cleared when it's opened again, see set_dropped),
##   bookmarks: [{id, chapter, paragraph, name, text, created, modified, deleted}] (see add_bookmark)

signal changed
signal book_changed(id: String)
signal chapter_saved(id: String, index: int)
signal saved  # something changed and is about to be written
signal progress_changed(id: String)  # reading position moved (last_read was stamped)

## Book fields kept in library.json; the rest is in meta/<id>.json.
const INDEX_FIELDS := ["progress", "last_read", "text_stamp"]

var books: Array = []
## sync key -> unix time the book was removed, so other devices remove it too.
var tombstones := {}
## book id -> a count that goes up whenever the book's meta file changes, so Sync
## can tell which books changed without comparing them (not kept between runs).
var revisions := {}

var _dirty := {}  # book id -> true: its meta file needs writing
var _index_dirty := false
var _flush_queued := false


func _ready() -> void:
	_load()
	_count_missing_words.call_deferred()


func _exit_tree() -> void:
	var t := Time.get_ticks_msec()
	flush()
	AppLog.info("close", "library saved in %d ms" % AppLog.since(t))


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		var t := Time.get_ticks_msec()
		flush()  # Android may stop the app any time after pausing it
		AppLog.info("library", "saved in %d ms" % AppLog.since(t))


# --- queries -----------------------------------------------------------------

func get_book(id: String) -> Dictionary:
	for b in books:
		if b.id == id:
			return b
	return {}


func find_by_url(url: String) -> Dictionary:
	var key := book_key(url)
	for b in books:
		if b.get("url", "") != "" and book_key(b.url) == key:
			return b
	return {}


func find_by_sync_key(key: String) -> Dictionary:
	for b in books:
		if sync_key(b) == key:
			return b
	return {}


## Identifies a book across devices: the book URL for web books, and title,
## author and chapter count for imported files (so the same EPUB imported on two
## devices is one book). Assigned once and kept.
static func sync_key(book: Dictionary) -> String:
	if book.get("sync_key", "") == "":
		if book.get("url", "") != "":
			book.sync_key = book_key(book.url)
		else:
			book.sync_key = "file:" + ("%s|%s|%d" % [book.title, book.author, book.chapters.size()]).to_lower().md5_text()
	return book.sync_key


## Books on sites with a plugin are identified the plugin's way, so the same book
## under two URLs (with and without a slug, say) is one book (see SourcePlugin.book_key).
static func book_key(url: String) -> String:
	var key := Plugins.book_key(url)
	if key != "":
		return key
	return url.to_lower().replace("https://", "").replace("http://", "").replace("www.", "").trim_suffix("/")


## The most recently read book that isn't dropped.
func last_read() -> Dictionary:
	var best := {}
	for b in books:
		if b.get("last_read", 0) > 0 and not b.get("dropped", false) and (best.is_empty() or b.last_read > best.last_read):
			best = b
	return best


func progress_ratio(book: Dictionary) -> float:
	var n: int = book.get("chapters", []).size()
	if n == 0:
		return 0.0
	return clampf(float(book.progress.chapter + 1) / n, 0.0, 1.0) if book.get("last_read", 0) > 0 else 0.0


## Read up to the last chapter (a serial with new chapters is no longer finished).
func is_finished(book: Dictionary) -> bool:
	var n: int = book.get("chapters", []).size()
	return n > 0 and book.get("last_read", 0) > 0 and book.progress.chapter >= n - 1


## Started, not finished and not dropped: what the library's Reading tab shows.
func is_reading(book: Dictionary) -> bool:
	return book.get("last_read", 0) > 0 and not book.get("dropped", false) and not is_finished(book)


# --- mutations ---------------------------------------------------------------

func add_book(data: Dictionary) -> Dictionary:
	var book := {
		"id": _new_id(), "title": "Untitled", "author": "", "kind": "web", "source": "file",
		"url": "", "cover": "", "cover_set": 0, "cover_url": "", "synopsis": "", "tags": [], "extra": {}, "rss_only": false,
		"total_words": 0, "chapters": [], "progress": {"chapter": 0, "paragraph": 0},
		"added": Time.get_unix_time_from_system(), "last_read": 0, "last_checked": 0,
		"modified": Time.get_unix_time_from_system(),
	}
	book.merge(data, true)
	books.append(book)
	save(book.id)
	changed.emit()
	return book


func update_book(id: String, fields: Dictionary) -> void:
	var b := get_book(id)
	if b.is_empty():
		return
	b.merge(fields, true)
	if not fields.has("modified"):
		b.modified = Time.get_unix_time_from_system()
	save(id)
	book_changed.emit(id)
	changed.emit()


## tombstone: record the removal so synced devices remove the book too.
func remove_book(id: String, tombstone := true) -> void:
	var b := get_book(id)
	if b.is_empty():
		return
	if tombstone:
		tombstones[sync_key(b)] = Time.get_unix_time_from_system()
	books.erase(b)
	_dirty.erase(id)
	revisions.erase(id)
	_remove_dir(book_dir(id))
	if b.cover != "" and FileAccess.file_exists(b.cover):
		DirAccess.remove_absolute(b.cover)
	save_index()
	DirAccess.remove_absolute(_meta_path(id))
	changed.emit()


func set_progress(id: String, chapter: int, paragraph: int) -> void:
	var b := get_book(id)
	if b.is_empty():
		return
	b.progress = {"chapter": chapter, "paragraph": paragraph}
	b.last_read = Time.get_unix_time_from_system()
	save_index()
	progress_changed.emit(id)


## A dropped book leaves the Reading tab until it's opened again.
func set_dropped(id: String, dropped: bool) -> void:
	var b := get_book(id)
	if not b.is_empty() and b.get("dropped", false) != dropped:
		update_book(id, {"dropped": dropped})


# --- bookmarks ---------------------------------------------------------------
# A bookmark marks a paragraph (an index as in progress.paragraph) of a chapter.
# Removed bookmarks stay in the list with deleted = true, so sync can remove them
# on other devices too. They don't change the book's `modified`: sync merges them
# one by one, the most recently changed version of each winning.

## The book's bookmarks (not removed ones), in reading order.
static func bookmarks(book: Dictionary) -> Array:
	var out: Array = book.get("bookmarks", []).filter(func(m): return not m.get("deleted", false))
	out.sort_custom(func(a, b): return a.chapter < b.chapter or (a.chapter == b.chapter and a.paragraph < b.paragraph))
	return out


## The bookmark at a paragraph, or {}.
static func bookmark_at(book: Dictionary, chapter: int, paragraph: int) -> Dictionary:
	for m in bookmarks(book):
		if m.chapter == chapter and m.paragraph == paragraph:
			return m
	return {}


## text: the start of the paragraph, shown under the name.
func add_bookmark(id: String, chapter: int, paragraph: int, name: String, text: String) -> Dictionary:
	var b := get_book(id)
	if b.is_empty():
		return {}
	var now := Time.get_unix_time_from_system()
	var m := {
		"id": "%x%04x" % [int(now * 1000), randi() % 0xffff], "chapter": chapter, "paragraph": paragraph,
		"name": name.strip_edges(), "text": text, "created": now, "modified": now, "deleted": false,
	}
	if not b.has("bookmarks"):
		b.bookmarks = []
	b.bookmarks.append(m)
	_bookmarks_changed(id)
	return m


func rename_bookmark(id: String, bookmark_id: String, name: String) -> void:
	var m := _find_bookmark(id, bookmark_id)
	if not m.is_empty():
		m.name = name.strip_edges()
		m.modified = Time.get_unix_time_from_system()
		_bookmarks_changed(id)


func remove_bookmark(id: String, bookmark_id: String) -> void:
	var m := _find_bookmark(id, bookmark_id)
	if not m.is_empty():
		m.deleted = true
		m.modified = Time.get_unix_time_from_system()
		_bookmarks_changed(id)


## Replaces the whole list (Sync, after merging other devices' bookmarks).
func set_bookmarks(id: String, list: Array) -> void:
	var b := get_book(id)
	if not b.is_empty():
		b.bookmarks = list
		_bookmarks_changed(id)


func _find_bookmark(id: String, bookmark_id: String) -> Dictionary:
	for m in get_book(id).get("bookmarks", []):
		if m.id == bookmark_id:
			return m
	return {}


func _bookmarks_changed(id: String) -> void:
	save(id)
	book_changed.emit(id)


# --- chapter cache -----------------------------------------------------------

func book_dir(id: String) -> String:
	return Settings.data_dir() + "/books/" + id


func has_chapter(id: String, index: int) -> bool:
	return FileAccess.file_exists("%s/%d.json" % [book_dir(id), index])


## Returns {title, paragraphs, excerpt} or {} when not cached.
func load_chapter(id: String, index: int) -> Dictionary:
	var path := "%s/%d.json" % [book_dir(id), index]
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func store_chapter(id: String, index: int, title: String, paragraphs: PackedStringArray, excerpt := false) -> void:
	DirAccess.make_dir_recursive_absolute(book_dir(id))
	var f := FileAccess.open("%s/%d.json" % [book_dir(id), index], FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"title": title, "paragraphs": Array(paragraphs), "excerpt": excerpt}))
		f.close()
		if not excerpt:
			var b := get_book(id)
			if index < b.get("chapters", []).size():
				b.chapters[index].words = word_count(paragraphs)
				save(id)
			_texts_changed(id)
			chapter_saved.emit(id, index)


func _texts_changed(id: String) -> void:
	var b := get_book(id)
	if not b.is_empty():
		b.text_stamp = Time.get_unix_time_from_system()
		save_index()


## Words in a chapter's paragraphs. Hyphenated words and contractions count once.
static func word_count(paragraphs: PackedStringArray) -> int:
	var re := HtmlText._re("[\\p{L}\\p{N}]+(?:['’\\-][\\p{L}\\p{N}]+)*")
	var n := 0
	for p in paragraphs:
		n += re.search_all(HtmlText.plain(p)).size()
	return n


## Words in the book's saved chapters: {words, chapters} (chapters: how many were counted).
static func saved_words(book: Dictionary) -> Dictionary:
	var words := 0
	var counted := 0
	for c in book.get("chapters", []):
		if c.has("words"):
			words += int(c.words)
			counted += 1
	return {"words": words, "chapters": counted}


## Counts the words of saved chapters that have no count yet (books from before
## word counts, or chapter lists replaced by Sync), a few chapters per frame.
func _count_missing_words() -> void:
	for b in books.duplicate():
		var dir := DirAccess.open(book_dir(b.id))
		if dir == null:
			continue
		var counted := false
		var since_frame := 0
		for f in dir.get_files():
			var i := f.get_basename().to_int() if f.ends_with(".json") and f.get_basename().is_valid_int() else -1
			if i < 0 or i >= b.chapters.size() or b.chapters[i].has("words"):
				continue
			var ch := load_chapter(b.id, i)
			if ch.is_empty() or ch.get("excerpt", false) or not (ch.get("paragraphs") is Array):
				continue
			b.chapters[i].words = word_count(PackedStringArray(ch.paragraphs))
			counted = true
			since_frame += 1
			if since_frame >= 10:
				since_frame = 0
				await get_tree().process_frame
				if get_book(b.id).is_empty():
					break
		if counted and not get_book(b.id).is_empty():
			save(b.id)
			book_changed.emit(b.id)


## Index of a chapter in a book by URL (compared the site plugin's way, see
## SourcePlugin.chapter_key). -1 when missing.
func chapter_index(book: Dictionary, url: String) -> int:
	var key := chapter_key(url)
	for i in book.chapters.size():
		if chapter_key(book.chapters[i].url) == key:
			return i
	return -1


static func chapter_key(url: String) -> String:
	var key := Plugins.chapter_key(url)
	if key != "":
		return key
	return url.to_lower().replace("https://", "").replace("http://", "").replace("www.", "").get_slice("#", 0).trim_suffix("/")


## Replace a book's chapter list, moving cached chapter files to their new positions.
func replace_chapters(id: String, new_chapters: Array) -> void:
	var b := get_book(id)
	if b.is_empty():
		return
	var dir := book_dir(id)
	var moves := []
	for old_i in b.chapters.size():
		if not has_chapter(id, old_i):
			continue
		var key := chapter_key(b.chapters[old_i].url)
		for new_i in new_chapters.size():
			if chapter_key(new_chapters[new_i].url) == key:
				moves.append([old_i, new_i])
				if b.chapters[old_i].has("words"):
					new_chapters[new_i].words = b.chapters[old_i].words
				break
	for mv in moves:
		DirAccess.rename_absolute("%s/%d.json" % [dir, mv[0]], "%s/%d.json.tmp" % [dir, mv[0]])
	var d := DirAccess.open(dir)
	if d:
		for f in d.get_files():
			if f.ends_with(".json"):
				d.remove(f)  # chapters that no longer exist
	for mv in moves:
		DirAccess.rename_absolute("%s/%d.json.tmp" % [dir, mv[0]], "%s/%d.json" % [dir, mv[1]])
	var prog: int = b.progress.chapter
	var prog_key := chapter_key(b.chapters[prog].url) if prog < b.chapters.size() else ""
	var mark_keys := []
	for m in b.get("bookmarks", []):
		mark_keys.append(chapter_key(b.chapters[m.chapter].url) if m.chapter < b.chapters.size() else "")
	b.chapters = new_chapters
	for i in new_chapters.size():
		var key := chapter_key(new_chapters[i].url)
		if key == prog_key:
			b.progress.chapter = i
		for k in mark_keys.size():
			if mark_keys[k] == key:
				b.bookmarks[k].chapter = i
	b.rss_only = false
	b.modified = Time.get_unix_time_from_system()
	b.text_stamp = b.modified
	save(id)
	book_changed.emit(id)
	changed.emit()


## True when the chapter is cached with its full text (not just an RSS preview).
func has_full_chapter(id: String, index: int) -> bool:
	var path := "%s/%d.json" % [book_dir(id), index]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	# JSON.stringify sorts keys, so store_chapter's excerpt flag comes first
	return f.get_buffer(32).get_string_from_utf8().begins_with("{\"excerpt\":false")


func cached_count(id: String) -> int:
	var dir := DirAccess.open(book_dir(id))
	return dir.get_files().size() if dir else 0


func save_cover(id: String, image: Image) -> String:
	if image == null or image.is_empty():
		return ""
	if image.get_width() > 400:
		image.resize(400, int(image.get_height() * 400.0 / image.get_width()), Image.INTERPOLATE_LANCZOS)
	DirAccess.make_dir_recursive_absolute(Settings.data_dir() + "/covers")
	var path := "%s/covers/%s.png" % [Settings.data_dir(), id]
	image.save_png(path)
	return path


## Replaces a book's cover with one picked by hand (an image file's bytes:
## PNG, JPEG or WebP). Sync passes it on to the other devices. -> error or ""
func set_cover_from_bytes(id: String, bytes: PackedByteArray) -> String:
	if get_book(id).is_empty():
		return "The book is gone"
	var img := Net.image_from_bytes(bytes)
	if img == null:
		return "Could not read the image. Pick a PNG, JPEG or WebP file."
	var path := save_cover(id, img)
	if path == "":
		return "Could not save the cover"
	update_book(id, {"cover": path, "cover_set": Time.get_unix_time_from_system()})
	return ""


## Changes an imported book's title, author, description and tags (any of
## them; tags as an Array or comma-separated text). -> error or ""
func edit_details(id: String, fields: Dictionary) -> String:
	var b := get_book(id)
	if b.is_empty():
		return "The book is gone"
	if not is_file_book(b):
		return "Only imported books can be edited"
	var out := {}
	if fields.has("title"):
		var t := str(fields.title).strip_edges()
		if t == "":
			return "The title can't be empty"
		out.title = t
	for f in ["author", "synopsis"]:
		if fields.has(f):
			out[f] = str(fields[f]).strip_edges()
	if fields.has("tags"):
		out.tags = clean_tags(fields.tags)
	sync_key(b)  # assigned from the title, so fix it before that changes
	update_book(id, out)
	return ""


## Tags without blanks, extra spaces or repeats (ignoring case), from an Array
## or comma-separated text: "Fantasy, litrpg ,, fantasy" -> ["Fantasy", "litrpg"].
static func clean_tags(tags: Variant) -> Array:
	var list: Array = tags if tags is Array else str(tags).split(",")
	var out := []
	var seen := {}
	for t in list:
		var tag := HtmlText._re("\\s+").sub(str(t), " ", true).strip_edges()
		if tag != "" and not seen.has(tag.to_lower()):
			seen[tag.to_lower()] = true
			out.append(tag)
	return out


## True when a book has the tag, ignoring case.
static func has_tag(book: Dictionary, tag: String) -> bool:
	for t in book.get("tags", []):
		if str(t).to_lower() == tag.to_lower():
			return true
	return false


## Every tag in the library, sorted, each once (ignoring case).
func all_tags() -> Array:
	var all := []
	for b in books:
		all.append_array(b.get("tags", []))
	var out := clean_tags(all)
	out.sort_custom(func(a, c): return a.naturalnocasecmp_to(c) < 0)
	return out


# --- import ------------------------------------------------------------------

## Imports an .epub or .txt file. Returns the new book, or {"error": msg}.
func import_file(path: String) -> Dictionary:
	var parsed := read_file(path)
	return parsed if parsed.has("error") else add_imported(parsed, path)


## Reads an .epub or .txt file: the loader's result ({title, author, chapters,
## ...}, see EpubLoader and TxtLoader), or {"error": msg}.
func read_file(path: String) -> Dictionary:
	var kind := path.get_extension().to_lower()
	var source := path
	if not kind in ["epub", "txt", "text", "md"] and path.begins_with("content://"):
		# Android's file picker returns content:// URIs without a file name, so
		# copy the file and tell the type from its contents (EPUB is a zip).
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			return {"error": "Could not read the selected file"}
		kind = "epub" if bytes.slice(0, 4) == PackedByteArray([0x50, 0x4B, 0x03, 0x04]) else "txt"
		source = "user://import.%s" % kind
		var f := FileAccess.open(source, FileAccess.WRITE)
		if f == null:
			return {"error": "Could not copy the selected file"}
		f.store_buffer(bytes)
		f.close()
	var parsed: Dictionary
	match kind:
		"epub":
			parsed = EpubLoader.load_epub(source)
		"txt", "text", "md":
			parsed = TxtLoader.load_txt(source)
		_:
			return {"error": "Unsupported file type: %s" % path.get_extension()}
	if source != path:
		DirAccess.remove_absolute(source)
	if not parsed.has("error"):
		parsed.kind = "txt" if kind in ["text", "md"] else kind
	return parsed


## Adds a file read with read_file to the library as a new book.
func add_imported(parsed: Dictionary, path: String) -> Dictionary:
	var chapters: Array = parsed.chapters
	var book := add_book({
		"title": parsed.title, "author": parsed.get("author", ""), "kind": parsed.get("kind", "epub"),
		"source": "file", "synopsis": parsed.get("synopsis", ""), "tags": parsed.get("tags", []),
		"chapters": chapters.map(func(c): return {"title": c.title, "url": ""}),
		"file": path,
	})
	for i in chapters.size():
		store_chapter(book.id, i, chapters[i].title, chapters[i].paragraphs)
	if parsed.get("cover") is Image:
		book.cover = save_cover(book.id, parsed.cover)
		save(book.id)
		changed.emit()
	return book


## Reads an EPUB to fill a web book's chapters from (see fill_from_epub): the
## EpubLoader result, or {"error": msg}, also when the EPUB is of another book.
func read_epub_for(id: String, path: String) -> Dictionary:
	var b := get_book(id)
	if b.is_empty():
		return {"error": "That book is no longer in your library"}
	var parsed := read_file(path)
	if parsed.has("error"):
		return parsed
	var epub_url := _epub_book_url(parsed)
	if epub_url != "" and b.url != "" and book_key(epub_url) != book_key(b.url):
		return {"error": "This EPUB is of a different book (%s)" % parsed.title}
	return parsed


# --- later parts of an imported book -------------------------------------------
# A serial saved as an EPUB now and then (c1-485, then c486-496, ...) is one book:
# each later file's new chapters are added to the end of it.

## True for books imported from a file, which can have later parts added.
static func is_file_book(book: Dictionary) -> bool:
	return book.get("kind", "") in ["epub", "txt"] and book.get("url", "") == ""


## The imported book that a file read with read_file looks like a later part of
## (see same_series), the most recently used one if several. {} if none.
func find_series_book(parsed: Dictionary) -> Dictionary:
	var best := {}
	for b in books:
		if is_file_book(b) and same_series(b, parsed):
			if best.is_empty() or maxf(b.last_read, b.added) > maxf(best.last_read, best.added):
				best = b
	return best


## True when a book and a file have the same title, ignoring case, punctuation
## and a chapter range at the end ("The Path of Ascension - c486-496"), and the
## same author unless one of them has none.
static func same_series(book: Dictionary, parsed: Dictionary) -> bool:
	var a := _title_key(series_title(book.title))
	if a == "" or a != _title_key(series_title(parsed.get("title", ""))):
		return false
	var x := _title_key(book.get("author", ""))
	var y := _title_key(parsed.get("author", ""))
	return x == "" or y == "" or x == y


## A book's title without a chapter range or part number at the end:
## "Title - c486-496", "Title (Chapters 1-50)", "Title, Vol. 2" -> "Title".
static func series_title(title: String) -> String:
	var re := HtmlText._re("(?i)[\\s,:;\\-–—(\\[]+(?:c|ch|chs|chap|chapters?|vol|volumes?|books?|parts?|#)?\\.?\\s*\\d+(?:\\s*(?:-|–|—|to)\\s*\\d+)?\\s*[)\\]]?\\s*$")
	var t := re.sub(title, "").strip_edges()
	return t if t != "" else title


## The chapters of a file read with read_file that a book doesn't have yet (see
## unseen_chapters), compared with the text it has stored.
func new_chapters_for(id: String, parsed: Dictionary) -> Array:
	var b := get_book(id)
	if b.is_empty():
		return []
	var texts := []
	for i in b.chapters.size():
		texts.append(load_chapter(id, i).get("paragraphs", []))
	return unseen_chapters(b.chapters, texts, parsed.chapters, _title_key(series_title(b.title)))


## The new chapters (from a loader) that aren't already among a book's chapters
## (`have`, with their paragraphs in `have_text`), so a file that overlaps the
## book adds only what comes after. A chapter is already there when one has
## - its chapter number (see number_key; not one that several chapters have,
##   like "Chapter 207 (1/2)" and "(2/2)"),
## - or the same text (its longest paragraph, ignoring punctuation) and not
##   another chapter number (a later chapter can repeat a passage),
## - or, for a short page without much text, the same title.
## `series`: the book's title as _title_key(series_title()), see number_key.
static func unseen_chapters(have: Array, have_text: Array, chapters: Array, series := "") -> Array:
	var numbers := {}  # number key -> how many chapters have it
	var prints := {}
	var titles := {}
	for i in have.size():
		var n := number_key(have[i].title, series)
		if n != "":
			numbers[n] = numbers.get(n, 0) + 1
		titles[_title_key(have[i].title)] = true
		var fp := _fingerprint(have_text[i] if i < have_text.size() else [])
		if fp != "":
			prints[fp] = n
	var out := []
	for c in chapters:
		var n := number_key(c.title, series)
		var fp := _fingerprint(c.paragraphs)
		if n != "" and numbers.get(n, 0) == 1:
			continue
		if fp != "" and prints.has(fp) and (n == "" or prints[fp] == "" or prints[fp] == n):
			continue
		if fp == "" and titles.has(_title_key(c.title)):
			continue
		out.append(c)
	return out


## A chapter title's number with what comes before "Chapter" (a side story's
## name, "Book 2"), except the book's own title: "Chapter 12" and "The Book
## Chapter 12: Name" -> "|12", "Side Story Ch. 3" -> "sidestory|3", "12. Name"
## -> "|12". "" if it has no number.
static func number_key(title: String, series := "") -> String:
	var m := HtmlText._re("(?i)^(.*?)\\b(?:chapter|chap|ch)\\.?\\s*(\\d+)(?!\\d)").search(title)
	if m:
		var before := _title_key(m.get_string(1))
		return "%s|%d" % ["" if before == series else before, m.get_string(2).to_int()]
	m = HtmlText._re("^\\s*(\\d+)(?!\\d)").search(title)
	return "|%d" % m.get_string(1).to_int() if m else ""


## A chapter's longest paragraph as letters and digits only, or "" when it's too
## short to tell chapters apart by.
static func _fingerprint(paragraphs: Array) -> String:
	var best := ""
	for p in paragraphs:
		if not HtmlText.is_heading(p) and str(p).length() > best.length():
			best = str(p)
	var key := HtmlText._re("[^\\p{L}\\p{N}]+").sub(HtmlText.plain(best).to_lower(), "", true)
	return key if key.length() >= 60 else ""


## Adds chapters (from new_chapters_for) to the end of a book. Fills in the
## author, description and cover from the file when the book has none.
func append_chapters(id: String, parsed: Dictionary, chapters: Array) -> void:
	var b := get_book(id)
	if b.is_empty() or chapters.is_empty():
		return
	sync_key(b)  # assigned from the chapter count, so fix it before that changes
	var start: int = b.chapters.size()
	for k in chapters.size():
		store_chapter(id, start + k, chapters[k].title, chapters[k].paragraphs)
		b.chapters.append({"title": chapters[k].title, "url": ""})
	for f in ["author", "synopsis"]:
		if str(b.get(f, "")) == "" and str(parsed.get(f, "")) != "":
			b[f] = parsed[f]
	if (b.cover == "" or not FileAccess.file_exists(b.cover)) and parsed.get("cover") is Image:
		b.cover = save_cover(id, parsed.cover)
	b.modified = Time.get_unix_time_from_system()
	save(id)
	book_changed.emit(id)
	changed.emit()


## The link of the book an EPUB was made from: the one in its metadata, or else
## the first link on its first page that a plugin knows as a book. "" if none.
static func _epub_book_url(epub: Dictionary) -> String:
	if epub.get("book_url", "") != "":
		return epub.book_url
	for link in epub.get("links", []):
		if Plugins.book_key(link) != "":
			return link
	return ""


## Fills a web book's missing chapters from an EPUB of the same book (e.g. one
## made by WebToEpub), read with read_epub_for. Chapters are matched by their
## link when the EPUB has one, otherwise by title. Downloaded chapters are left
## alone; RSS previews are replaced. Chapters the site no longer lists (taken
## down, or stubbed for a published book) are added in their place, see
## _add_epub_only_chapters. -> {filled, matched, added}
func fill_from_epub(id: String, epub: Dictionary) -> Dictionary:
	var b := get_book(id)
	if b.is_empty():
		return {"filled": 0, "matched": 0, "added": 0}
	var at := _epub_match_indexes(b, epub.chapters)
	var filled := 0
	var matched := 0
	for k in at.size():
		var i: int = at[k]
		if i < 0:
			continue
		matched += 1
		if not has_full_chapter(id, i):
			store_chapter(id, i, b.chapters[i].title, epub.chapters[k].paragraphs)
			filled += 1
	# with nothing matched, the EPUB may well be of another book
	var added := _add_epub_only_chapters(id, epub.chapters, at) if matched > 0 else 0
	if filled > 0 and added == 0:
		book_changed.emit(id)
		changed.emit()
	return {"filled": filled, "matched": matched, "added": added}


## Adds the EPUB chapters that matched none of a web book's chapters (`at`, see
## _epub_match_indexes) and that it doesn't have under another title either (see
## unseen_chapters), each right after the chapter before it in the EPUB, or
## first if none is. Pages before the first matched chapter (a title page, the
## book's description) are left out unless they have a chapter number, and so
## are short pages without a number ("Volume 2"). Their link is the EPUB's, or
## else one made up from the title (see is_epub_only), so Sync and later
## refreshes know them. -> how many
func _add_epub_only_chapters(id: String, epub_chapters: Array, at: Array) -> int:
	var b := get_book(id)
	var texts := []
	for i in b.chapters.size():
		texts.append(load_chapter(id, i).get("paragraphs", []))
	var unmatched := []
	var seen_match := false
	for k in at.size():
		var c: Dictionary = epub_chapters[k]
		seen_match = seen_match or at[k] >= 0
		var numbered := number_key(c.title) != ""
		if at[k] < 0 and (numbered or (seen_match and _fingerprint(c.paragraphs) != "")):
			unmatched.append(c)
	var fresh := unseen_chapters(b.chapters, texts, unmatched, _title_key(series_title(b.title)))
	if fresh.is_empty():
		return 0
	var list: Array = b.chapters.duplicate()  # the same dictionaries, so files and progress follow them
	var urls := {}
	for c in list:
		urls[chapter_key(c.url)] = true
	var added := []  # [chapter entry, paragraphs]
	var last := -1  # where the previous EPUB chapter is in `list`
	for k in at.size():
		if at[k] >= 0:
			var orig: Dictionary = b.chapters[at[k]]
			last = list.find_custom(func(c): return is_same(c, orig))
		elif fresh.any(func(c): return is_same(c, epub_chapters[k])):
			var c: Dictionary = epub_chapters[k]
			var url: String = c.get("url", "")
			if url == "" or urls.has(chapter_key(url)):
				var base := "epub:" + (_title_key(c.title) if _title_key(c.title) != "" else "chapter")
				url = base
				var n := 2
				while urls.has(chapter_key(url)):
					url = "%s-%d" % [base, n]
					n += 1
			urls[chapter_key(url)] = true
			var entry := {"title": c.title, "url": url, "date": 0}
			last += 1
			list.insert(last, entry)
			added.append([entry, c.paragraphs])
	var rss_only: bool = b.get("rss_only", false)
	replace_chapters(id, list)
	b.rss_only = rss_only  # replace_chapters clears it
	for a in added:
		store_chapter(id, b.chapters.find_custom(func(c): return is_same(c, a[0])), a[0].title, PackedStringArray(a[1]))
	return added.size()


## True for a chapter added from an EPUB with no link of its own (see
## _add_epub_only_chapters): it can't be downloaded again.
static func is_epub_only(chapter: Dictionary) -> bool:
	return str(chapter.get("url", "")).begins_with("epub:")


## Pairs EPUB chapters with a book's chapters: -> [[book index, epub chapter]].
## See _epub_match_indexes.
static func match_epub_chapters(book: Dictionary, epub_chapters: Array) -> Array:
	var at := _epub_match_indexes(book, epub_chapters)
	var pairs := []
	for k in at.size():
		if at[k] >= 0:
			pairs.append([at[k], epub_chapters[k]])
	return pairs


## For each EPUB chapter, the index of the book's chapter it is, or -1.
## By link where the EPUB chapter has one; by title (ignoring case, punctuation
## and a leading chapter number like "12. ") where it doesn't and exactly one
## chapter has that title, unless the two start with different chapter numbers.
## An EPUB chapter titled only "Chapter 12" (a title the tool that made it didn't
## know) matches the one chapter numbered 12.
static func _epub_match_indexes(book: Dictionary, epub_chapters: Array) -> Array:
	var by_key := {}
	var by_title := {}
	var by_number := {}
	for i in book.chapters.size():
		var ch: Dictionary = book.chapters[i]
		if ch.get("url", "") != "":
			by_key[chapter_key(ch.url)] = i
		var t := _title_key(ch.title)
		by_title[t] = -1 if by_title.has(t) else i  # -1: more than one chapter has it
		var n := HtmlText._re("(?i)^\\s*(?:chapter\\s+)?(\\d+)(?!\\d)").search(ch.title)
		if n:
			by_number[n.get_string(1).to_int()] = -1 if by_number.has(n.get_string(1).to_int()) else i
	var out := []
	var used := {}
	for c in epub_chapters:
		var i: int = -1
		if c.get("url", "") != "":
			i = by_key.get(chapter_key(c.url), -1)
		else:
			i = by_title.get(_title_key(c.title), -1)
			if i >= 0 and _numbers_differ(c.title, book.chapters[i].title):
				i = -1  # "30 - Home" isn't "167 - Home"
			var placeholder := HtmlText._re("(?i)^\\s*chapter\\s+(\\d+)\\s*$").search(c.title)
			if i < 0 and placeholder:
				i = by_number.get(placeholder.get_string(1).to_int(), -1)
		if i >= 0 and used.has(i):
			i = -1
		if i >= 0:
			used[i] = true
		out.append(i)
	return out


## True when both titles start with a chapter number and they aren't the same.
static func _numbers_differ(a: String, b: String) -> bool:
	var x := number_key(a)
	var y := number_key(b)
	return x != "" and y != "" and x != y


static func _title_key(title: String) -> String:
	var t := HtmlText._re("^\\s*\\d+\\s*[.):\\-–—]\\s*").sub(title.to_lower(), "")
	return HtmlText._re("[^\\p{L}\\p{N}]+").sub(t, "", true)


# --- persistence -------------------------------------------------------------

## Marks a book's details (all books with no id) and the book list as changed;
## they're written at the end of the frame (or call flush).
func save(id := "") -> void:
	for b in (books if id == "" else [get_book(id)]):
		if not b.is_empty():
			_dirty[b.id] = true
			revisions[b.id] = revisions.get(b.id, 0) + 1
	save_index()


## Marks only library.json as changed: the book list, reading positions,
## text stamps and tombstones.
func save_index() -> void:
	_index_dirty = true
	if not _flush_queued:
		_flush_queued = true
		flush.call_deferred()
	saved.emit()


## Writes what save and save_index marked. Meta files go first, so library.json
## never lists a book whose file isn't there.
func flush() -> void:
	_flush_queued = false
	if not _dirty.is_empty():
		DirAccess.make_dir_recursive_absolute(Settings.data_dir() + "/meta")
	for id in _dirty:
		var b := get_book(id)
		if not b.is_empty():
			var meta := b.duplicate()
			for f in INDEX_FIELDS:
				meta.erase(f)
			_write(_meta_path(id), JSON.stringify(meta))
	_dirty.clear()
	if _index_dirty:
		_index_dirty = false
		var list := books.map(func(b):
			var e := {"id": b.id}
			for f in INDEX_FIELDS:
				if b.has(f):
					e[f] = b[f]
			return e)
		_write(Settings.data_dir() + "/library.json", JSON.stringify({"version": 2, "books": list, "tombstones": tombstones}))


func _meta_path(id: String) -> String:
	return "%s/meta/%s.json" % [Settings.data_dir(), id]


## Writes to a temporary file first, so a crash part way leaves the old file.
static func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null:
		push_error("Library: can't write %s" % path)
		return
	f.store_string(text)
	f.close()
	if DirAccess.rename_absolute(path + ".tmp", path) != OK:
		DirAccess.remove_absolute(path)
		DirAccess.rename_absolute(path + ".tmp", path)


func _load() -> void:
	var path := Settings.data_dir() + "/library.json"
	if not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary and parsed.get("books") is Array):
		return
	if parsed.get("tombstones") is Dictionary:
		tombstones = parsed.tombstones
	if int(parsed.get("version", 1)) < 2:
		books = parsed.books  # the old layout: everything in library.json
	else:
		for e in parsed.books:
			if not (e is Dictionary and e.has("id")):
				continue
			var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(_meta_path(e.id))) if FileAccess.file_exists(_meta_path(e.id)) else null
			if not (meta is Dictionary):
				push_error("Library: details of book %s are missing" % e.id)
				continue
			meta.merge(e, true)
			books.append(meta)
	for b in books:  # JSON numbers come back as floats
		b.progress = {"chapter": int(b.progress.chapter), "paragraph": int(b.progress.paragraph)}
		for m in b.get("bookmarks", []):
			m.chapter = int(m.chapter)
			m.paragraph = int(m.paragraph)
		if not b.has("modified"):
			b.modified = maxf(b.get("added", 0), b.get("last_checked", 0))
	if int(parsed.get("version", 1)) < 2:
		save()
		flush()


func _new_id() -> String:
	return "%x%04x" % [int(Time.get_unix_time_from_system()), randi() % 0xffff]


func _norm_url(url: String) -> String:
	return url.to_lower().replace("https://", "").replace("http://", "").replace("www.", "").trim_suffix("/")


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(path)
