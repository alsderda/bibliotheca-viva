class_name TxtLoader
## Plain text import. Splits chapters on "Chapter ..." lines, otherwise every ~60 paragraphs.


static func load_txt(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "File not found"}
	var text := FileAccess.get_file_as_string(path).replace("\r\n", "\n")
	var heading := HtmlText._re("(?i)^(chapter|book|part|prologue|epilogue)\\b.{0,60}$")
	var chapters: Array = []
	var current := {"title": "Beginning", "paragraphs": PackedStringArray()}
	for block in text.split("\n\n"):
		var p := block.replace("\n", " ").strip_edges()
		if p == "":
			continue
		var safe := p.replace("[", "\u0002").replace("]", "[rb]").replace("\u0002", "[lb]")
		if heading.search(p) or current.paragraphs.size() >= 60:
			if current.paragraphs.size() > 0:
				chapters.append(current)
			var title: String = p.left(80) if heading.search(p) else "Part %d" % (chapters.size() + 1)
			current = {"title": title, "paragraphs": PackedStringArray()}
			if heading.search(p):
				current.paragraphs.append(HtmlText.HEADING + safe)
				continue
		current.paragraphs.append(safe)
	if current.paragraphs.size() > 0:
		chapters.append(current)
	if chapters.is_empty():
		return {"error": "The file is empty"}
	return {"title": path.get_file().get_basename().capitalize(), "author": "", "chapters": chapters}
