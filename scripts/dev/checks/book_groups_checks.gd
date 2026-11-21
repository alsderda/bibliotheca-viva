extends RefCounted
## Self-test checks for this area. `t` is the self-test node: call t.check(name, got, want) for each check.


static func _covers(groups: Array, total: int) -> bool:
	if groups.is_empty():
		return true
	var prev := 0
	for g in groups:
		if int(g["start"]) != prev or int(g["end"]) <= int(g["start"]):
			return false
		prev = int(g["end"])
	return prev == total


static func _plain(count: int) -> PackedStringArray:
	var titles := PackedStringArray()
	for i in count:
		titles.append("Chapter %d - Filler" % (i + 1))
	return titles


func run(t: Node) -> void:
	_prefix_tags(t)
	_volumes(t)
	_pipe_style(t)
	_dotted(t)
	_leading_unknown(t)
	_prologue_epilogue(t)
	_end_forms(t)
	_intermission(t)
	_arcs(t)
	_arcs_ignored(t)
	_noise(t)
	_lone_decimal(t)
	_fallback_shapes(t)
	_scale(t)


func _prefix_tags(t: Node) -> void:
	var titles := PackedStringArray([
		"B1 Chapter 1: The Drop",
		"B1 Chapter 2: The Rise",
		"B2 Interlude 1: Visions",
		"B2 Chapter 3: The Return",
		"B3 Chapter 1: New Dawn",
	])
	var got := BookGroups.split(titles, 50)
	t.check("book groups prefix tags", got, [
		{"label": "Book 1", "start": 0, "end": 2},
		{"label": "Book 2", "start": 2, "end": 4},
		{"label": "Book 3", "start": 4, "end": 5},
	])
	t.check("book groups prefix tags cover", _covers(got, titles.size()), true)


func _volumes(t: Node) -> void:
	var tagged := PackedStringArray([
		"Ch. 01 - The Guild",
		"Ch. 02 - The Market",
		"V2, Ch. 01 - The Harbor",
		"V2, Ch. 02 - The Storm",
	])
	var got := BookGroups.split(tagged, 50)
	t.check("book groups untagged first volume", got, [
		{"label": "Volume 1", "start": 0, "end": 2},
		{"label": "Volume 2", "start": 2, "end": 4},
	])
	t.check("book groups untagged first volume cover", _covers(got, tagged.size()), true)
	var words := PackedStringArray(["Volume 1 | Ash", "Vol. 2 | Tide", "VOL 3 - Dawn"])
	got = BookGroups.split(words, 50)
	t.check("book groups volume word forms", got, [
		{"label": "Volume 1", "start": 0, "end": 1},
		{"label": "Volume 2", "start": 1, "end": 2},
		{"label": "Volume 3", "start": 2, "end": 3},
	])
	t.check("book groups volume word forms cover", _covers(got, words.size()), true)


func _pipe_style(t: Node) -> void:
	var titles := PackedStringArray([
		"Book 1 | Chapter 1: Ember",
		"Book 1 | Chapter 2: Ash",
		"Book 2 | Chapter 1: Tide",
		"Book 3 | Chapter 1A: Day 12 - Wind",
	])
	var got := BookGroups.split(titles, 50)
	t.check("book groups pipe style", got, [
		{"label": "Book 1", "start": 0, "end": 2},
		{"label": "Book 2", "start": 2, "end": 3},
		{"label": "Book 3", "start": 3, "end": 4},
	])
	t.check("book groups pipe style cover", _covers(got, titles.size()), true)
	var numbered := PackedStringArray(["Book One | Dawn", "Book Two | Dusk", "Book III | Night"])
	got = BookGroups.split(numbered, 50)
	t.check("book groups word and roman numbers", got, [
		{"label": "Book 1", "start": 0, "end": 1},
		{"label": "Book 2", "start": 1, "end": 2},
		{"label": "Book 3", "start": 2, "end": 3},
	])
	t.check("book groups word and roman numbers cover", _covers(got, numbered.size()), true)


func _dotted(t: Node) -> void:
	var titles := PackedStringArray([
		"1. A Cold Start",
		"2. The Long Road",
		"3. Small Mercies",
		"49. Book 1 Epilogue",
		"(50) 2.1. The Quiet Thief",
		"(51) 2.2. The Lantern",
		"EXCITING ANNOUNCEMENT! Book 1 is Out in Print!",
		"(52) 2.3. The Quarry",
		"(53) 3.1. Slow Rivers",
		"(54) 3.2. Slow Ember",
		"(55) 3.3. Last Light",
	])
	var got := BookGroups.split(titles, 50)
	t.check("book groups dotted with plain first book", got, [
		{"label": "Book 1", "start": 0, "end": 4},
		{"label": "Book 2", "start": 4, "end": 8},
		{"label": "Book 3", "start": 8, "end": 11},
	])
	t.check("book groups dotted cover", _covers(got, titles.size()), true)


func _leading_unknown(t: Node) -> void:
	var titles := PackedStringArray()
	for i in 12:
		titles.append("Chapter %d - Clash" % (41 + i))
	titles.append("Chapter 907 - Up the Hill - START OF BOOK 13")
	titles.append("Chapter 908 - Afterglow")
	titles.append("Chapter 909 - START OF BOOK 14")
	titles.append("Chapter 910 - First Light")
	var got := BookGroups.split(titles, 5)
	t.check("book groups unknown leading stretch", got, [
		{"label": "Chapters 1–5", "start": 0, "end": 5},
		{"label": "Chapters 6–10", "start": 5, "end": 10},
		{"label": "Chapters 11–12", "start": 10, "end": 12},
		{"label": "Book 13", "start": 12, "end": 14},
		{"label": "Book 14", "start": 14, "end": 16},
	])
	t.check("book groups unknown leading stretch cover", _covers(got, titles.size()), true)


func _prologue_epilogue(t: Node) -> void:
	var titles := PackedStringArray([
		"Chapter 60 - The Hollow",
		"Chapter 65 - Book One Epilogue: Marta",
		"Chapter 66 - Book Two Prologue: Petra",
		"Chapter 67 - Green Shoots",
	])
	var got := BookGroups.split(titles, 50)
	t.check("book groups prologue epilogue pair", got, [
		{"label": "Book 1", "start": 0, "end": 2},
		{"label": "Book 2", "start": 2, "end": 4},
	])
	t.check("book groups prologue epilogue pair cover", _covers(got, titles.size()), true)


func _end_forms(t: Node) -> void:
	var titles := PackedStringArray([
		"Chapter 1 - Ash",
		"End of Book One and Character AMA (not a chapter)",
		"Start of Book 2 | Day 9 - Rain",
		"Chapter 3 - Tide",
	])
	var got := BookGroups.split(titles, 50)
	t.check("book groups end and start phrases", got, [
		{"label": "Book 1", "start": 0, "end": 2},
		{"label": "Book 2", "start": 2, "end": 4},
	])
	t.check("book groups end and start phrases cover", _covers(got, titles.size()), true)


func _intermission(t: Node) -> void:
	var titles := PackedStringArray([
		"Chapter 40 - Last Stand",
		"Author's Notes - End of Book 2 / Character Q&A",
		"Book 2/3 Intermission - Character Q&A",
		"Book 3 | Chapter 1: Daybreak",
		"Book 3 | Chapter 2: Noon",
	])
	var got := BookGroups.split(titles, 50)
	t.check("book groups intermission joins next book", got, [
		{"label": "Book 1", "start": 0, "end": 1},
		{"label": "Book 2", "start": 1, "end": 2},
		{"label": "Book 3", "start": 2, "end": 5},
	])
	t.check("book groups intermission cover", _covers(got, titles.size()), true)


func _arcs(t: Node) -> void:
	var titles := PackedStringArray([
		"Arc 1 Begin: The Gears",
		"Chapter 2 - Cogs",
		"Arc 2 Begin Chapter 56: The Old Mill",
		"Chapter 57 - Smoke",
	])
	var got := BookGroups.split(titles, 50)
	t.check("book groups arc only story", got, [
		{"label": "Arc 1", "start": 0, "end": 2},
		{"label": "Arc 2", "start": 2, "end": 4},
	])
	t.check("book groups arc only story cover", _covers(got, titles.size()), true)


func _arcs_ignored(t: Node) -> void:
	var titles := PackedStringArray([
		"Book 1 | Chapter 1: Ember",
		"Kicking Off The Harbor Arc",
		"Arc 2 Begin: Side Winds",
		"Book 2 | Chapter 1: Tide",
	])
	var got := BookGroups.split(titles, 50)
	t.check("book groups arcs ignored with books", got, [
		{"label": "Book 1", "start": 0, "end": 3},
		{"label": "Book 2", "start": 3, "end": 4},
	])
	t.check("book groups arcs ignored cover", _covers(got, titles.size()), true)


func _noise(t: Node) -> void:
	var titles := PackedStringArray([
		"Book Three available in print",
		"EXCITING ANNOUNCEMENT! Book 1 is Out in Print!",
		"Not A Chapter - Book 1 Feedback",
		"Book 1 Premium Hardcover Announcement",
		"Some Series Book Two Audiobook now available!",
		"Book 2/3 Intermission - Character Q&A",
		"27. Book After Book Burns",
		"102.5 current character sheet",
		"Chapter 61: A Battle [Part 1/2]",
		"Chapter 43 - Brushfire (Part 1)",
		"Kicking Off The Harbor Arc",
		"Interlude XII - Rowan",
	])
	var flat := BookGroups.split(titles, 50)
	t.check("book groups noise stays flat", flat, [])
	t.check("book groups noise stays flat cover", _covers(flat, titles.size()), true)
	var got := BookGroups.split(titles, 5)
	t.check("book groups noise falls back", got, [
		{"label": "Chapters 1–5", "start": 0, "end": 5},
		{"label": "Chapters 6–10", "start": 5, "end": 10},
		{"label": "Chapters 11–12", "start": 10, "end": 12},
	])
	t.check("book groups noise falls back cover", _covers(got, titles.size()), true)


func _lone_decimal(t: Node) -> void:
	var alone := PackedStringArray(["Chapter 1 - Dawn", "102.5 current character sheet", "Chapter 2 - Dusk"])
	var flat := BookGroups.split(alone, 50)
	t.check("book groups lone decimal stays flat", flat, [])
	t.check("book groups lone decimal stays flat cover", _covers(flat, alone.size()), true)
	var titles := PackedStringArray([
		"(10) 2.1. Alpha",
		"(11) 2.2. Beta",
		"(12) 2.3. Gamma",
		"102.5 current character sheet",
		"(13) 3.1. Delta",
		"(14) 3.2. Epsilon",
		"(15) 3.3. Zeta",
	])
	var got := BookGroups.split(titles, 50)
	t.check("book groups stray decimal stays put", got, [
		{"label": "Book 2", "start": 0, "end": 4},
		{"label": "Book 3", "start": 4, "end": 7},
	])
	t.check("book groups stray decimal cover", _covers(got, titles.size()), true)


func _fallback_shapes(t: Node) -> void:
	var empty := BookGroups.split(PackedStringArray(), 50)
	t.check("book groups empty input", empty, [])
	t.check("book groups empty input cover", _covers(empty, 0), true)
	var short := _plain(5)
	var flat := BookGroups.split(short, 50)
	t.check("book groups short story stays flat", flat, [])
	t.check("book groups short story cover", _covers(flat, short.size()), true)
	var single := _plain(1)
	var one := BookGroups.split(single, 50)
	t.check("book groups single chapter stays flat", one, [])
	var exact := _plain(10)
	var got := BookGroups.split(exact, 5)
	t.check("book groups exact multiple", got, [
		{"label": "Chapters 1–5", "start": 0, "end": 5},
		{"label": "Chapters 6–10", "start": 5, "end": 10},
	])
	t.check("book groups exact multiple cover", _covers(got, exact.size()), true)
	var rest := _plain(12)
	got = BookGroups.split(rest, 5)
	t.check("book groups remainder block", got, [
		{"label": "Chapters 1–5", "start": 0, "end": 5},
		{"label": "Chapters 6–10", "start": 5, "end": 10},
		{"label": "Chapters 11–12", "start": 10, "end": 12},
	])
	t.check("book groups remainder block cover", _covers(got, rest.size()), true)
	var tail := _plain(6)
	got = BookGroups.split(tail, 5)
	t.check("book groups single chapter block", got, [
		{"label": "Chapters 1–5", "start": 0, "end": 5},
		{"label": "Chapter 6", "start": 5, "end": 6},
	])
	t.check("book groups single chapter block cover", _covers(got, tail.size()), true)
	var trio := _plain(3)
	var each := [
		{"label": "Chapter 1", "start": 0, "end": 1},
		{"label": "Chapter 2", "start": 1, "end": 2},
		{"label": "Chapter 3", "start": 2, "end": 3},
	]
	got = BookGroups.split(trio, 1)
	t.check("book groups size one", got, each)
	t.check("book groups size one cover", _covers(got, trio.size()), true)
	got = BookGroups.split(trio, 0)
	t.check("book groups size zero clamps to one", got, each)
	t.check("book groups size zero cover", _covers(got, trio.size()), true)


func _scale(t: Node) -> void:
	var titles := PackedStringArray()
	for i in 2000:
		titles.append("B%d Chapter %d: Filler" % [i / 500 + 1, i % 500 + 1])
	var t0 := Time.get_ticks_usec()
	var got := BookGroups.split(titles, 50)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	t.check("book groups long list", got, [
		{"label": "Book 1", "start": 0, "end": 500},
		{"label": "Book 2", "start": 500, "end": 1000},
		{"label": "Book 3", "start": 1000, "end": 1500},
		{"label": "Book 4", "start": 1500, "end": 2000},
	])
	t.check("book groups long list cover", _covers(got, titles.size()), true)
	print("    book groups 2000 titles: %.1f ms" % ms)
