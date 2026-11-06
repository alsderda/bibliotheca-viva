class_name HtmlText
## Converts chapter HTML into reader paragraphs.
## Paragraphs are BBCode-safe strings that may contain [i] / [b] and
## a leading HEADING marker for headings.

const HEADING := "\u0001"

static var _re_cache := {}


static func _re(pattern: String) -> RegEx:
	if not _re_cache.has(pattern):
		var r := RegEx.new()
		r.compile(pattern)
		_re_cache[pattern] = r
	return _re_cache[pattern]


static func to_paragraphs(html: String) -> PackedStringArray:
	var s := html
	var body := _re("(?is)<body[^>]*>(.*)</body>").search(s)
	if body:
		s = body.get_string(1)
	s = _re("(?is)<(script|style|head|noscript|svg)[^>]*>.*?</\\1>").sub(s, "", true)
	s = _re("(?s)<!--.*?-->").sub(s, "", true)
	s = s.replace("\r", " ").replace("\n", " ").replace("\t", " ")
	s = s.replace("[", "\u0002").replace("]", "\u0003")
	s = _re("(?i)<br\\s*/?>").sub(s, "\n", true)
	s = _re("(?i)<h[1-6][^>]*>").sub(s, "\n" + HEADING, true)
	s = _re("(?i)</h[1-6]\\s*>").sub(s, "\n", true)
	s = _re("(?i)</?(p|div|li|ul|ol|blockquote|tr|table|section|article|header|footer|figure|figcaption|pre|dd|dt)(\\s[^>]*)?>").sub(s, "\n", true)
	s = _re("(?i)<hr[^>]*>").sub(s, "\n* * *\n", true)
	s = _re("(?i)<(em|i|cite)(\\s[^>]*)?>").sub(s, "[i]", true)
	s = _re("(?i)</(em|i|cite)\\s*>").sub(s, "[/i]", true)
	s = _re("(?i)<(strong|b)(\\s[^>]*)?>").sub(s, "[b]", true)
	s = _re("(?i)</(strong|b)\\s*>").sub(s, "[/b]", true)
	s = _re("<[^>]*>").sub(s, "", true)
	s = decode_entities(s)
	var out := PackedStringArray()
	var ws := _re("[ \\t\\r\\f\\v\\x{00a0}]+")
	for line in s.split("\n"):
		var p := ws.sub(line, " ", true).strip_edges()
		var is_heading := p.begins_with(HEADING) or p.find(HEADING) != -1
		p = p.replace(HEADING, "").strip_edges()
		if p == "" or p == "[i][/i]" or p == "[b][/b]":
			continue
		p = _balance(p).replace("\u0002", "[lb]").replace("\u0003", "[rb]")
		if plain(p).strip_edges() == "":
			continue
		out.append(HEADING + p if is_heading else p)
	return out


## Paragraph -> plain text (for TTS and previews).
static func plain(p: String) -> String:
	var s := p.replace(HEADING, "")
	s = _re("\\[/?[ib]\\]").sub(s, "", true)
	return s.replace("[lb]", "[").replace("[rb]", "]")


static func is_heading(p: String) -> bool:
	return p.begins_with(HEADING)


static func strip_tags(html: String) -> String:
	return decode_entities(_re("<[^>]*>").sub(html, "", true)).strip_edges()


static func decode_entities(s: String) -> String:
	if s.find("&") == -1:
		return s
	const NAMED := {
		"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
		"mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
		"rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™",
		"laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "eacute": "é",
		"egrave": "è", "agrave": "à", "ecirc": "ê", "ccedil": "ç", "uuml": "ü",
		"ouml": "ö", "auml": "ä", "szlig": "ß", "times": "×", "deg": "°", "shy": "",
	}
	var result := ""
	var last := 0
	for m in _re("&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);").search_all(s):
		result += s.substr(last, m.get_start() - last)
		var e := m.get_string(1)
		if e.begins_with("#x"):
			result += char(e.substr(2).hex_to_int())
		elif e.begins_with("#"):
			result += char(e.substr(1).to_int())
		elif NAMED.has(e):
			result += NAMED[e]
		else:
			result += m.get_string()
		last = m.get_end()
	return result + s.substr(last)


## Make [i]/[b] tags balanced inside a single paragraph.
static func _balance(p: String) -> String:
	for tag in ["i", "b"]:
		var depth := 0
		var fixed := ""
		var parts := _re("(\\[/?%s\\])" % tag).search_all(p)
		var last := 0
		for m in parts:
			fixed += p.substr(last, m.get_start() - last)
			if m.get_string() == "[%s]" % tag:
				depth += 1
				fixed += m.get_string()
			elif depth > 0:
				depth -= 1
				fixed += m.get_string()
			last = m.get_end()
		fixed += p.substr(last)
		for _i in depth:
			fixed += "[/%s]" % tag
		p = fixed
	return p
