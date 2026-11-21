class_name BookGroups
extends RefCounted
## Groups the Contents tab's chapter list: detected books when the titles
## reveal them ("Book 2", "Volume 1", "Arc 3"), otherwise fixed-size blocks.


const NUMBER_WORDS := {
	"one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
	"six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
	"eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
	"sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
}
const ROMAN_NUMBERS := {
	"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5,
	"vi": 6, "vii": 7, "viii": 8, "ix": 9, "x": 10,
	"xi": 11, "xii": 12, "xiii": 13, "xiv": 14, "xv": 15,
	"xvi": 16, "xvii": 17, "xviii": 18, "xix": 19, "xx": 20,
}

static var _prefix_re: RegEx
static var _start_a_re: RegEx
static var _start_b_re: RegEx
static var _end_a_re: RegEx
static var _end_b_re: RegEx
static var _dotted_re: RegEx


## Splits a chapter list into groups for the Contents tab.
## `titles`: the chapter titles in order. `fallback_size`: chapters per group when no books are detected.
## Returns an Array of Dictionaries, in order, covering every index exactly once with no gaps:
##   {"label": String, "start": int, "end": int}   # start inclusive, end exclusive, 0-based chapter indices
## Returns [] when the list should stay flat (empty, or short with no detected books).
static func split(titles: PackedStringArray, fallback_size: int) -> Array:
	if titles.is_empty():
		return []
	var size := maxi(fallback_size, 1)
	# Dotted "<book>.<chapter>" numbering only counts when it repeats: a lone
	# decimal chapter number is not a book.
	var counts := {}
	var shapes := PackedInt32Array()
	shapes.resize(titles.size())
	for i in titles.size():
		var shape := _dotted_n(titles[i])
		shapes[i] = shape
		if shape >= 1:
			counts[shape] = int(counts.get(shape, 0)) + 1
	var qualifying := 0
	for n in counts:
		if int(counts[n]) >= 3:
			qualifying += 1
	var dotted_on := qualifying >= 2
	var markers: Array = []
	markers.resize(titles.size())
	var has_book := false
	for i in titles.size():
		var dotted := 0
		if dotted_on and shapes[i] >= 1 and int(counts.get(shapes[i], 0)) >= 3:
			dotted = shapes[i]
		var found := _marker(titles[i], dotted)
		markers[i] = found
		if not found.is_empty() and str(found["fam"]) != "Arc":
			has_book = true
	# A story told in books may still name arcs; the books win.
	if has_book:
		for i in titles.size():
			var dated: Dictionary = markers[i]
			if not dated.is_empty() and str(dated["fam"]) == "Arc":
				markers[i] = {}
	var kinds := {}
	var books := PackedInt32Array()
	books.resize(titles.size())
	var current := 0
	var pending := 0
	var first_idx := -1
	var first_n := 0
	var first_fam := ""
	for i in titles.size():
		var marked: Dictionary = markers[i]
		# A lower number than the book we are in is a recap or an old
		# announcement, not time travel.
		if not marked.is_empty() and current >= 1 and int(marked["n"]) < current:
			marked = {}
		if marked.is_empty():
			if pending >= 1:
				var next := pending + 1
				books[i] = next
				if not kinds.has(next):
					kinds[next] = str(kinds.get(pending, "Book"))
				current = next
			elif current >= 1:
				books[i] = current
			else:
				books[i] = 0
			pending = 0
		else:
			var n := int(marked["n"])
			var fam := str(marked["fam"])
			if first_idx < 0:
				first_idx = i
				first_n = n
				first_fam = fam
			kinds[n] = fam
			books[i] = n
			current = n
			pending = n if str(marked["typ"]) == "END" else 0
	if first_idx < 0:
		return _fallback(titles.size(), size)
	if first_n <= 2:
		var lead := maxi(first_n - 1, 1)
		if not kinds.has(lead):
			kinds[lead] = first_fam
		for i in range(first_idx):
			books[i] = lead
	var seen := {}
	for b in books:
		if b >= 1:
			seen[b] = true
	if seen.size() < 2:
		return _fallback(titles.size(), size)
	var out: Array = []
	var run := 0
	if first_n > 2 and first_idx > 0:
		out.append_array(_fallback_range(0, first_idx, size))
		run = first_idx
	var i := run
	while i < titles.size():
		var b := books[i]
		var j := i + 1
		while j < titles.size() and books[j] == b:
			j += 1
		out.append({"label": "%s %d" % [str(kinds.get(b, "Book")), b], "start": i, "end": j})
		i = j
	return out


## Fixed-size blocks, or [] when the whole list fits in one block (flat list).
static func _fallback(total: int, size: int) -> Array:
	if total <= size:
		return []
	return _fallback_range(0, total, size)


## Fixed-size blocks covering [start, end), labelled with 1-based numbers.
static func _fallback_range(start: int, end: int, size: int) -> Array:
	var out: Array = []
	var i := start
	while i < end:
		var j := mini(i + size, end)
		var label := "Chapter %d" % (i + 1) if j == i + 1 else "Chapters %d–%d" % [i + 1, j]
		out.append({"label": label, "start": i, "end": j})
		i = j
	return out


## The book marker of one title ({"n", "fam", "typ"} with typ IN/START/END),
## or {} when it has none. `dotted` is the title's dotted book number, or 0.
static func _marker(title: String, dotted: int) -> Dictionary:
	var m := _prefix_rx().search(title)
	if m != null:
		for g in [1, 2, 3]:
			var tok := m.get_string(g)
			if tok == "":
				continue
			var word_n := _parse_number(tok)
			if word_n >= 1:
				return {"n": word_n, "fam": "Book" if g == 1 else "Volume", "typ": "IN"}
			break
		for g in [4, 5]:
			var digits := m.get_string(g)
			if digits != "" and digits.to_int() >= 1:
				return {"n": digits.to_int(), "fam": "Book" if g == 4 else "Volume", "typ": "IN"}
	m = _start_a_rx().search(title)
	if m != null:
		var start_n := _parse_number(m.get_string(2))
		if start_n >= 1:
			return {"n": start_n, "fam": _family(m.get_string(1)), "typ": "START"}
	m = _start_b_rx().search(title)
	if m != null:
		var begins_n := _parse_number(m.get_string(2))
		if begins_n >= 1:
			return {"n": begins_n, "fam": _family(m.get_string(1)), "typ": "START"}
	m = _end_a_rx().search(title)
	if m != null:
		var end_n := _parse_number(m.get_string(2))
		if end_n >= 1:
			return {"n": end_n, "fam": _family(m.get_string(1)), "typ": "END"}
	m = _end_b_rx().search(title)
	if m != null:
		var epilogue_n := _parse_number(m.get_string(2))
		if epilogue_n >= 1:
			return {"n": epilogue_n, "fam": _family(m.get_string(1)), "typ": "END"}
	if dotted >= 1:
		return {"n": dotted, "fam": "Book", "typ": "IN"}
	return {}


## The book number of a "<book>.<chapter>" title start, or 0.
static func _dotted_n(title: String) -> int:
	var m := _dotted_rx().search(title)
	if m == null:
		return 0
	var n := m.get_string(1).to_int()
	return n if n >= 1 else 0


## Digits, a number word or a roman numeral (0 when none of those).
static func _parse_number(token: String) -> int:
	if token.is_valid_int():
		var n := token.to_int()
		return n if n >= 1 else 0
	var lower := token.to_lower()
	if NUMBER_WORDS.has(lower):
		return int(NUMBER_WORDS[lower])
	if ROMAN_NUMBERS.has(lower):
		return int(ROMAN_NUMBERS[lower])
	return 0


## The label family of a kind word: Book, Volume or Arc.
static func _family(kind: String) -> String:
	match kind.to_lower():
		"arc":
			return "Arc"
		"volume", "vol", "vol.":
			return "Volume"
	return "Book"


static func _prefix_rx() -> RegEx:
	if _prefix_re == null:
		_prefix_re = RegEx.create_from_string("(?i)^\\s*(?:\\(\\d+\\)\\s*)?(?:Book\\s+([A-Za-z0-9]+)|Volume\\s+([A-Za-z0-9]+)|Vol\\.?\\s+([A-Za-z0-9]+)|B(\\d+)|V(\\d+))(?:\\s*(?:$|[,:|–—-])|\\s+[^/])")
	return _prefix_re


static func _start_a_rx() -> RegEx:
	if _start_a_re == null:
		_start_a_re = RegEx.create_from_string("(?i)\\bstart\\s+of\\s+(book|volume|vol\\.?|arc)\\s+([A-Za-z0-9]+)(?![A-Za-z0-9])")
	return _start_a_re


static func _start_b_rx() -> RegEx:
	if _start_b_re == null:
		_start_b_re = RegEx.create_from_string("(?i)\\b(book|volume|vol\\.?|arc)\\s+([A-Za-z0-9]+)\\s+(begins|begin|starts|start|prologue)\\b")
	return _start_b_re


static func _end_a_rx() -> RegEx:
	if _end_a_re == null:
		_end_a_re = RegEx.create_from_string("(?i)\\bend\\s+of\\s+(book|volume|vol\\.?|arc)\\s+([A-Za-z0-9]+)(?![A-Za-z0-9])")
	return _end_a_re


static func _end_b_rx() -> RegEx:
	if _end_b_re == null:
		_end_b_re = RegEx.create_from_string("(?i)\\b(book|volume|vol\\.?|arc)\\s+([A-Za-z0-9]+)\\s+epilogue\\b")
	return _end_b_re


static func _dotted_rx() -> RegEx:
	if _dotted_re == null:
		_dotted_re = RegEx.create_from_string("^\\s*(?:\\(\\d+\\)\\s*)?(\\d+)\\.(\\d+)(?:\\.|\\s)")
	return _dotted_re
