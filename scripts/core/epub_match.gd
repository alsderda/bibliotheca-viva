class_name EpubMatch
## Matching an EPUB file to a book: which of its chapters the book already has (by
## link, chapter number, title or text), which ones are new, and which link the
## file was made from. Reads book and chapter dictionaries (see Library) and
## never changes them.


## True when a book and a file have the same title, ignoring case, punctuation
## and a chapter range at the end ("The Path of Ascension - c486-496"), and the
## same author unless one of them has none.
static func same_series(book: Dictionary, parsed: Dictionary) -> bool:
	var a := title_key(series_title(book.title))
	if a == "" or a != title_key(series_title(parsed.get("title", ""))):
		return false
	var x := title_key(book.get("author", ""))
	var y := title_key(parsed.get("author", ""))
	return x == "" or y == "" or x == y


## A book's title without a chapter range or part number at the end:
## "Title - c486-496", "Title (Chapters 1-50)", "Title, Vol. 2" -> "Title".
static func series_title(title: String) -> String:
	var re := HtmlText._re("(?i)[\\s,:;\\-–—(\\[]+(?:c|ch|chs|chap|chapters?|vol|volumes?|books?|parts?|#)?\\.?\\s*\\d+(?:\\s*(?:-|–|—|to)\\s*\\d+)?\\s*[)\\]]?\\s*$")
	var t := re.sub(title, "").strip_edges()
	return t if t != "" else title


## The new chapters (from a loader) that aren't already among a book's chapters
## (`have`, with their paragraphs in `have_text`), so a file that overlaps the
## book adds only what comes after. A chapter is already there when one has
## - its chapter number (see number_key; not one that several chapters have,
##   like "Chapter 207 (1/2)" and "(2/2)"),
## - or the same text (its longest paragraph, ignoring punctuation) and not
##   another chapter number (a later chapter can repeat a passage),
## - or, for a short page without much text, the same title.
## `series`: the book's title as title_key(series_title()), see number_key.
static func unseen_chapters(have: Array, have_text: Array, chapters: Array, series := "") -> Array:
	var numbers := {}  # number key -> how many chapters have it
	var prints := {}
	var titles := {}
	for i in have.size():
		var n := number_key(have[i].title, series)
		if n != "":
			numbers[n] = numbers.get(n, 0) + 1
		titles[title_key(have[i].title)] = true
		var fp := fingerprint(have_text[i] if i < have_text.size() else [])
		if fp != "":
			prints[fp] = n
	var out := []
	for c in chapters:
		var n := number_key(c.title, series)
		var fp := fingerprint(c.paragraphs)
		if n != "" and numbers.get(n, 0) == 1:
			continue
		if fp != "" and prints.has(fp) and (n == "" or prints[fp] == "" or prints[fp] == n):
			continue
		if fp == "" and titles.has(title_key(c.title)):
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
		var before := title_key(m.get_string(1))
		return "%s|%d" % ["" if before == series else before, m.get_string(2).to_int()]
	m = HtmlText._re("^\\s*(\\d+)(?!\\d)").search(title)
	return "|%d" % m.get_string(1).to_int() if m else ""


## A chapter's longest paragraph as letters and digits only, or "" when it's too
## short to tell chapters apart by.
static func fingerprint(paragraphs: Array) -> String:
	var best := ""
	for p in paragraphs:
		if not HtmlText.is_heading(p) and str(p).length() > best.length():
			best = str(p)
	var key := HtmlText._re("[^\\p{L}\\p{N}]+").sub(HtmlText.plain(best).to_lower(), "", true)
	return key if key.length() >= 60 else ""


## The link of the book an EPUB was made from: the one in its metadata, or else
## the first link on its first page that a plugin knows as a book. "" if none.
static func epub_book_url(epub: Dictionary) -> String:
	if epub.get("book_url", "") != "":
		return epub.book_url
	for link in epub.get("links", []):
		if Plugins.book_key(link) != "":
			return link
	return ""


## True for a chapter added from an EPUB with no link of its own (see
## Library._add_epub_only_chapters): it can't be downloaded again.
static func is_epub_only(chapter: Dictionary) -> bool:
	return str(chapter.get("url", "")).begins_with("epub:")


## Pairs EPUB chapters with a book's chapters: -> [[book index, epub chapter]].
## See epub_match_indexes.
static func match_epub_chapters(book: Dictionary, epub_chapters: Array) -> Array:
	var at := epub_match_indexes(book, epub_chapters)
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
static func epub_match_indexes(book: Dictionary, epub_chapters: Array) -> Array:
	var by_key := {}
	var by_title := {}
	var by_number := {}
	for i in book.chapters.size():
		var ch: Dictionary = book.chapters[i]
		if ch.get("url", "") != "":
			by_key[Library.chapter_key(ch.url)] = i
		var t := title_key(ch.title)
		by_title[t] = -1 if by_title.has(t) else i  # -1: more than one chapter has it
		var n := HtmlText._re("(?i)^\\s*(?:chapter\\s+)?(\\d+)(?!\\d)").search(ch.title)
		if n:
			by_number[n.get_string(1).to_int()] = -1 if by_number.has(n.get_string(1).to_int()) else i
	var out := []
	var used := {}
	for c in epub_chapters:
		var i: int = -1
		if c.get("url", "") != "":
			i = by_key.get(Library.chapter_key(c.url), -1)
		else:
			i = by_title.get(title_key(c.title), -1)
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


static func title_key(title: String) -> String:
	var t := HtmlText._re("^\\s*\\d+\\s*[.):\\-–—]\\s*").sub(title.to_lower(), "")
	return HtmlText._re("[^\\p{L}\\p{N}]+").sub(t, "", true)
