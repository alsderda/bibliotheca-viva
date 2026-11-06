class_name BookSearch
extends RefCounted
## Finding text in a book's chapters (the reader's Search tab).

const SPECIAL := "\\^$.|?*+()[]{}"


## A RegEx for `query`. Plain text ignores case; with `regex` the pattern is used as
## written, so `(?i)` and `\b` work there. null when the query is empty or doesn't compile.
static func compile(query: String, regex: bool) -> RegEx:
	if query == "":
		return null
	var re := RegEx.new()
	if re.compile(query if regex else "(?i)" + escape(query), false) != OK:
		return null
	return re


## `s` with regex special characters escaped, so it matches literally.
static func escape(s: String) -> String:
	var out := ""
	for c in s:
		out += ("\\" + c) if SPECIAL.contains(c) else c
	return out


## Start and end of each match in `text`. Empty matches (like `a*`) are left out.
static func find_all(re: RegEx, text: String) -> Array:
	var spans := []
	for m in re.search_all(text):
		if m.get_end() > m.get_start():
			spans.append(Vector2i(m.get_start(), m.get_end()))
	return spans


## A line of bbcode around the match at `span` in `text`, with the match in bold and
## `color`. Starts and ends at a space when it's cut, and marks the cut with "…".
static func snippet(text: String, span: Vector2i, color: String, radius := 70) -> String:
	text = text.replace("\n", " ")
	var a := maxi(0, span.x - radius)
	var b := mini(text.length(), span.y + radius)
	if a > 0:
		var sp := text.find(" ", a)
		if sp != -1 and sp < span.x:
			a = sp + 1
	if b < text.length():
		var sp := text.rfind(" ", b)
		if sp > span.y:
			b = sp
	return "%s%s[b][color=%s]%s[/color][/b]%s%s" % [
		"…" if a > 0 else "", esc(text.substr(a, span.x - a)), color,
		esc(text.substr(span.x, span.y - span.x)), esc(text.substr(span.y, b - span.y)),
		"…" if b < text.length() else ""]


## Plain text made safe to put in bbcode.
static func esc(s: String) -> String:
	return s.replace("[", "\u0002").replace("]", "[rb]").replace("\u0002", "[lb]")
