class_name ReaderMarkup
## BBCode string helpers for the reader's paragraphs: the text a label shows for
## some BBCode, marking a span of that text, and escaping plain text.


## The text a bbcode paragraph shows: tags dropped, [lb]/[rb] as brackets.
static func visible_text(bb: String) -> String:
	return mark_span(bb, 0, 0, "", "", true)


## Wraps visible characters `from`..`to` of `bb` in `open`/`close`, closing and reopening
## around any tag inside so the result stays properly nested. With `text_only`, returns
## just the visible text instead.
static func mark_span(bb: String, from: int, to: int, open: String, close: String, text_only := false) -> String:
	var out := ""
	var pos := 0          # visible characters so far
	var marking := false
	var i := 0
	while i < bb.length():
		var token := bb[i]
		var visible := true
		if token == "[":
			var j := bb.find("]", i)
			if j != -1:
				token = bb.substr(i, j - i + 1)
				visible = token == "[lb]" or token == "[rb]"
		i += token.length()
		if text_only:
			if visible:
				out += "[" if token == "[lb]" else ("]" if token == "[rb]" else token)
			continue
		var inside := visible and pos >= from and pos < to
		if marking and not inside:
			out += close
			marking = false
		if inside and not marking:
			out += open
			marking = true
		out += token
		if visible:
			pos += 1
	if marking:
		out += close
	return out


static func esc(s: String) -> String:
	return s.replace("[", "\u0002").replace("]", "[rb]").replace("\u0002", "[lb]")
