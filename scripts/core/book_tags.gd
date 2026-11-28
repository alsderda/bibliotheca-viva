class_name BookTags
## Tags on books: cleaning them, the tags the Tag picker offers, tag aliases (a main
## tag and the tags that count as it, from the "tag_aliases" setting) and the
## search that completes a typed tag. Reads book dictionaries and Library.books
## (see Library) and never changes them; the alias cache is its only state.


## Lowercase alias -> main tag from the "tag_aliases" setting; null until needed.
## Cached because matches_tag runs once per book on every filter pass.
static var _aliases_cache: Variant = null


## Drops the alias cache; call it when the "tag_aliases" setting changes.
static func clear_alias_cache() -> void:
	_aliases_cache = null


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


## True when a book has the tag or its plugin offers the tag for it in the Tag
## picker (see picker_tags), counting an alias as its main tag and ignoring case.
static func matches_tag(book: Dictionary, tag: String) -> bool:
	var to_main := _alias_map()
	var want := str(to_main.get(tag.to_lower(), tag)).to_lower()
	for t in book.get("tags", []):
		if str(to_main.get(str(t).to_lower(), t)).to_lower() == want:
			return true
	for t in picker_tags(book):
		if str(to_main.get(str(t).to_lower(), t)).to_lower() == want:
			return true
	return false


static func _alias_map() -> Dictionary:
	if _aliases_cache == null:
		var to_main := {}
		for g in clean_aliases(Settings.get_value("tag_aliases")):
			for a in g.aliases:
				to_main[str(a).to_lower()] = g.tag
		_aliases_cache = to_main
	return _aliases_cache


## The tags the Tag picker offers for a book: its own, or what its plugin picks
## (SourcePlugin.library_tags) unless the reader set the book's tags by hand.
static func picker_tags(book: Dictionary) -> Array:
	var p := Plugins.get_plugin(str(book.get("source", "")))
	return p.library_tags(book) if p and not book.get("tags_set", false) else book.get("tags", [])


## Every tag the Tag picker offers, each replaced by its main tag (see
## clean_aliases), sorted, each once (ignoring case). With a source (a plugin
## id, "web" or "file"), only the tags of that source's books.
static func all_tags(source := "") -> Array:
	var to_main := _alias_map()
	var all := []
	for b in Library.books:
		if source != "" and str(b.get("source", "")) != source:
			continue
		for t in picker_tags(b):
			all.append(to_main.get(str(t).to_lower(), t))
	var out := clean_tags(all)
	out.sort_custom(func(a, c): return a.naturalnocasecmp_to(c) < 0)
	return out


## Every tag the books themselves have (not just those the Tag picker offers),
## sorted, each once (ignoring case).
static func book_tags() -> Array:
	return _sorted_tags(func(b): return b.get("tags", []))


static func _sorted_tags(tags_of: Callable) -> Array:
	var all := []
	for b in Library.books:
		all.append_array(tags_of.call(b))
	var out := clean_tags(all)
	out.sort_custom(func(a, c): return a.naturalnocasecmp_to(c) < 0)
	return out


## Tag alias groups cleaned for saving under the "tag_aliases" setting: an
## Array of {"tag": main tag, "aliases": [tags]} (tags cleaned as clean_tags
## does). Drops groups with no main tag and repeats of a main tag (ignoring
## case; the first group wins). Drops an alias that is its own group's main
## tag, any group's main tag, or already an alias in an earlier group, so an
## alias always leads to one main tag in one step. Keeps groups with no aliases
## left. Accepts aliases as an Array or comma-separated text.
static func clean_aliases(groups: Variant) -> Array:
	if not (groups is Array):
		return []
	var items: Array = groups
	var main_seen := {}
	for g in items:
		if not (g is Dictionary) or not g.has("tag"):
			continue
		var main := HtmlText._re("\\s+").sub(str(g.get("tag", "")), " ", true).strip_edges()
		if main != "" and not main_seen.has(main.to_lower()):
			main_seen[main.to_lower()] = true
	var claimed := {}
	var emitted := {}
	var out := []
	for g in items:
		if not (g is Dictionary) or not g.has("tag"):
			continue
		var main := HtmlText._re("\\s+").sub(str(g.get("tag", "")), " ", true).strip_edges()
		if main == "" or emitted.has(main.to_lower()):
			continue
		emitted[main.to_lower()] = true
		var aliases := []
		for a in clean_tags(g.get("aliases", [])):
			var low := str(a).to_lower()
			if low == main.to_lower() or main_seen.has(low) or claimed.has(low):
				continue
			claimed[low] = true
			aliases.append(a)
		out.append({"tag": main, "aliases": aliases})
	return out


## The main tag that `tag` is an alias of in `groups` (as clean_aliases returns
## them), spelled as the group spells it, ignoring case. A tag that is no alias
## comes back unchanged; so does a main tag.
static func resolve_tag(groups: Array, tag: String) -> String:
	var low := tag.to_lower()
	for g in groups:
		if not (g is Dictionary):
			continue
		var main := str(g.get("tag", ""))
		if main == "" or main.to_lower() == low:
			continue
		var raw: Variant = g.get("aliases", [])
		if not (raw is Array):
			continue
		var aliases: Array = raw
		for a in aliases:
			if str(a).to_lower() == low:
				return main
	return tag


## resolve_tag with the "tag_aliases" setting.
static func main_tag(tag: String) -> String:
	return resolve_tag(clean_aliases(Settings.get_value("tag_aliases")), tag)


## The aliases of a main tag in the "tag_aliases" setting, ignoring case; []
## when it has none.
static func aliases_of(tag: String) -> Array:
	for g in clean_aliases(Settings.get_value("tag_aliases")):
		if str(g.get("tag", "")).to_lower() == tag.to_lower():
			var aliases: Array = g.get("aliases", [])
			return aliases.duplicate()
	return []


## Tags from `all` that complete what's been typed so far, ignoring case: those
## starting with it first, then those with a word starting with it, then those
## containing it. Skips tags in `have` and the typed tag itself once it's
## complete. With nothing typed, every tag not in `have`.
static func match_tags(all: Array, have: Array, typed: String) -> Array:
	var low := typed.strip_edges().to_lower()
	var skip := {}
	for t in have:
		skip[str(t).to_lower()] = true
	var ranked := [[], [], []]
	for t in all:
		var tag := str(t)
		var lt := tag.to_lower()
		if skip.has(lt) or tag == typed.strip_edges():
			continue
		if low == "" or lt.begins_with(low):
			ranked[0].append(tag)
		elif (" " + lt).contains(" " + low) or ("-" + lt).contains("-" + low):
			ranked[1].append(tag)
		elif lt.contains(low):
			ranked[2].append(tag)
	return ranked[0] + ranked[1] + ranked[2]
