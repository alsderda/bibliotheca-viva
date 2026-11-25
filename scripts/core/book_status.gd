class_name BookStatus
## What state a book is in: reading progress, unread chapters, archive and
## favorite flags, and the short labels pages show for it. Reads book
## dictionaries (see Library) and never changes them.


static func progress_ratio(book: Dictionary) -> float:
	var n: int = book.get("chapters", []).size()
	if n == 0:
		return 0.0
	return clampf(float(book.progress.chapter + 1) / n, 0.0, 1.0) if book.get("last_read", 0) > 0 else 0.0


## Read up to the last chapter (a serial with new chapters is no longer finished).
static func is_finished(book: Dictionary) -> bool:
	var n: int = book.get("chapters", []).size()
	return n > 0 and book.get("last_read", 0) > 0 and book.progress.chapter >= n - 1


## Started and not finished, dropped or archived: what the library's Reading tab shows.
static func is_reading(book: Dictionary) -> bool:
	return book.get("last_read", 0) > 0 and not book.get("dropped", false) and not book.get("archived", false) and not is_finished(book)


static func is_archived(book: Dictionary) -> bool:
	return book.get("archived", false)


static func is_favorite(book: Dictionary) -> bool:
	return book.get("favorite", false)


## A chapter counts as unread past the reading position, and every chapter of a
## book never opened does.
static func is_unread(book: Dictionary, index: int) -> bool:
	return index > book.progress.chapter or book.last_read == 0


static func unread_count(book: Dictionary) -> int:
	return maxi(0, book.chapters.size() - (book.progress.chapter + 1 if book.last_read > 0 else 0))


## The web serials Updates shows and checks. Archived ones are left out, and
## only the chapter list's Check for new button in the reader checks them.
static func followed() -> Array:
	return Library.books.filter(func(b): return b.kind == "web" and not is_archived(b))


## Short label for the kind of book: EPUB, TXT, RSS or WEB.
static func kind_label(book: Dictionary) -> String:
	match book.kind:
		"epub": return "EPUB"
		"txt": return "TXT"
	return "RSS" if book.get("rss_only", false) else "WEB"


## Where the book comes from: its plugin's name, the site's host, or "Imported file".
static func source_name(book: Dictionary) -> String:
	if book.kind != "web":
		return "Imported file"
	var p := Plugins.for_url(book.url)
	return p.name if p else book.url.get_slice("/", 2).trim_prefix("www.")
