class_name BookSort
extends RefCounted
## Sort orders for the library grid. Pure functions on book dictionaries (see
## Library for the fields), so the self-test can check them headless.

## Sort key -> label shown in the library's sort picker, in picker order.
## "recent" (last read or added, whichever is later) is the default.
const ORDERS := {
	"recent": "Recent",
	"added": "Date added",
	"updated": "Last updated",
	"words": "Word count",
	"title": "Title",
	"author": "Author",
}


## The direction a key starts in when it is picked: newest / longest first for
## dates and word counts (true), A to Z for title and author (false).
static func default_descending(key: String) -> bool:
	return key != "title" and key != "author"


## The value a book is sorted by for a key:
##   recent:  maxf(last_read, added)
##   added:   added
##   updated: the newest chapter "date" (when the site released it); books
##            whose chapters have no dates (imported files) use
##            maxf(added, text_stamp) instead, so appending a later part counts
##   words:   total_words when > 0 (the site's count), else Library.saved_words(book).words
##   title / author: the text, compared with naturalnocasecmp_to
## An unknown key sorts like "recent". Missing fields count as 0 or "".
static func value(book: Dictionary, key: String) -> Variant:
	var k := key if ORDERS.has(key) else "recent"
	match k:
		"added":
			return float(book.get("added", 0))
		"updated":
			var newest := 0.0
			for c in book.get("chapters", []):
				newest = maxf(newest, float(c.get("date", 0)))
			if newest > 0.0:
				return newest
			return maxf(float(book.get("added", 0)), float(book.get("text_stamp", 0)))
		"words":
			var site_count := float(book.get("total_words", 0))
			if site_count > 0.0:
				return site_count
			return Library.saved_words(book).get("words", 0)
		"title", "author":
			return str(book.get(k, ""))
		_:
			return maxf(float(book.get("last_read", 0)), float(book.get("added", 0)))


## Sorts books in place by key. Descending reverses the order of the values
## only: ties (equal values, e.g. two books with no word count) always fall
## back to title A to Z, then id, so the order is stable whichever way you sort.
static func sort(books: Array, key: String, descending: bool) -> void:
	var k := key if ORDERS.has(key) else "recent"
	var by_text := k == "title" or k == "author"
	# Each book's value is worked out once, not in every comparison: "updated"
	# and "words" walk every chapter, which adds up for long serials.
	var rows := []
	for b in books:
		rows.append([value(b, k), str(b.get("title", "")), str(b.get("id", "")), b])
	rows.sort_custom(func(a: Array, b: Array) -> bool:
		if by_text:
			var cmp: int = str(a[0]).naturalnocasecmp_to(str(b[0]))
			if cmp != 0:
				return cmp > 0 if descending else cmp < 0
		elif float(a[0]) != float(b[0]):
			return float(a[0]) > float(b[0]) if descending else float(a[0]) < float(b[0])
		var title_cmp: int = a[1].naturalnocasecmp_to(b[1])
		if title_cmp != 0:
			return title_cmp < 0
		return a[2] < b[2]
	)
	for i in rows.size():
		books[i] = rows[i][3]
