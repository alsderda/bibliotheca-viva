class_name EpubLoader
## Minimal EPUB 2/3 reader: metadata, cover, spine order and TOC titles.
## Books saved from the web also give each chapter's link (`url`, from WebToEpub)
## and links that may be the book's (`book_url` from the metadata, and `links`
## on the first page, where e.g. FicHub writes the original source), so their
## chapters can fill a web book.


static func load_epub(path: String) -> Dictionary:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"error": "Could not open EPUB: %s" % path.get_file()}
	var files := {}
	for f in zip.get_files():
		files[f] = true

	var container := _text(zip, "META-INF/container.xml")
	var m := HtmlText._re("full-path\\s*=\\s*\"([^\"]+)\"").search(container)
	if m == null:
		zip.close()
		return {"error": "Not a valid EPUB (missing container.xml)"}
	var opf_path := m.get_string(1)
	var base := opf_path.get_base_dir()
	var opf := _text(zip, opf_path)

	var title := _tag(opf, "dc:title")
	var author := _tag(opf, "dc:creator")
	var synopsis := HtmlText.strip_tags(HtmlText.decode_entities(_tag(opf, "dc:description")))
	var tags: Array = []
	for s in HtmlText._re("(?is)<dc:subject[^>]*>(.*?)</dc:subject>").search_all(opf):
		var t := HtmlText.decode_entities(s.get_string(1)).get_slice(" -- ", 0).strip_edges()
		if t != "" and not tags.has(t) and tags.size() < 6:
			tags.append(t)

	# links to the web pages the book and its chapters came from (WebToEpub
	# writes <dc:source id="id.<manifest id>">link</dc:source> for each chapter)
	var sources := {}
	for sm in HtmlText._re("(?is)<dc:source\\b[^>]*\\bid\\s*=\\s*[\"']id\\.([^\"']+)[\"'][^>]*>(.*?)</dc:source>").search_all(opf):
		sources[sm.get_string(1)] = HtmlText.decode_entities(sm.get_string(2).strip_edges())
	var book_url := HtmlText.decode_entities(_tag(opf, "dc:identifier"))
	if not book_url.begins_with("http"):
		book_url = ""

	# manifest
	var manifest := {}
	var cover_href := ""
	for item in HtmlText._re("(?is)<item\\b[^>]*>").search_all(opf):
		var tag := item.get_string()
		var id := _attr(tag, "id")
		var href := _join(base, _attr(tag, "href").uri_decode())
		manifest[id] = {"href": href, "type": _attr(tag, "media-type"), "props": _attr(tag, "properties")}
		if "cover-image" in manifest[id].props:
			cover_href = href
	if cover_href == "":
		var cm := HtmlText._re("(?is)<meta[^>]*name=\"cover\"[^>]*content=\"([^\"]+)\"").search(opf)
		if cm and manifest.has(cm.get_string(1)):
			cover_href = manifest[cm.get_string(1)].href

	# toc titles: file -> label (first one wins)
	var toc := {}
	for id in manifest:
		var it: Dictionary = manifest[id]
		if "nav" in it.props.split(" "):
			_read_nav(_text(zip, it.href), it.href.get_base_dir(), toc)
		elif it.type == "application/x-dtbncx+xml":
			_read_ncx(_text(zip, it.href), it.href.get_base_dir(), toc)

	# spine
	var chapters: Array = []
	var links := PackedStringArray()
	for ref in HtmlText._re("(?is)<itemref\\b[^>]*>").search_all(opf):
		var idref := _attr(ref.get_string(), "idref")
		if not manifest.has(idref) or _attr(ref.get_string(), "linear") == "no":
			continue
		var href: String = manifest[idref].href
		if not files.has(href):
			continue
		var html := _text(zip, href)
		var paragraphs := HtmlText.to_paragraphs(html)
		if paragraphs.is_empty():
			continue
		if chapters.is_empty():
			for lm in HtmlText._re("https?://[^\\s\"'<>]+").search_all(html):
				var link := HtmlText.decode_entities(lm.get_string())
				if not links.has(link) and not link.contains("w3.org/") and not link.contains("idpf.org/") and not link.contains("daisy.org/"):
					links.append(link)
		var ch_title: String = toc.get(href, "")
		if ch_title == "":
			for p in paragraphs:
				if HtmlText.is_heading(p):
					ch_title = HtmlText.plain(p).left(80)
					break
		if ch_title == "":
			ch_title = "Section %d" % (chapters.size() + 1)
		var url: String = sources.get(idref, "")
		chapters.append({"title": ch_title, "paragraphs": paragraphs, "url": url if url.begins_with("http") else ""})

	var cover: Image = null
	if cover_href != "" and files.has(cover_href):
		cover = Net.image_from_bytes(zip.read_file(cover_href))
	zip.close()

	if chapters.is_empty():
		return {"error": "No readable chapters found in %s" % path.get_file()}
	return {
		"title": HtmlText.decode_entities(title) if title != "" else path.get_file().get_basename(),
		"author": HtmlText.decode_entities(author), "synopsis": synopsis, "tags": tags,
		"cover": cover, "chapters": chapters, "book_url": book_url,
		"links": links,
	}


static func _read_nav(html: String, dir: String, toc: Dictionary) -> void:
	var nav := HtmlText._re("(?is)<nav[^>]*epub:type=\"toc\"[^>]*>(.*?)</nav>").search(html)
	var body := nav.get_string(1) if nav else html
	for a in HtmlText._re("(?is)<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>").search_all(body):
		var file := _join(dir, a.get_string(1).get_slice("#", 0).uri_decode())
		var label := HtmlText.strip_tags(a.get_string(2)).replace("\n", " ")
		if label != "" and not toc.has(file):
			toc[file] = label


static func _read_ncx(xml: String, dir: String, toc: Dictionary) -> void:
	for np in HtmlText._re("(?is)<navLabel>\\s*<text>(.*?)</text>\\s*</navLabel>\\s*<content[^>]*src=\"([^\"]+)\"").search_all(xml):
		var file := _join(dir, np.get_string(2).get_slice("#", 0).uri_decode())
		var label := HtmlText.strip_tags(np.get_string(1))
		if label != "" and not toc.has(file):
			toc[file] = label


static func _text(zip: ZIPReader, path: String) -> String:
	return zip.read_file(path).get_string_from_utf8()


static func _tag(xml: String, tag: String) -> String:
	var m := HtmlText._re("(?is)<%s[^>]*>(.*?)</%s>" % [tag, tag]).search(xml)
	return m.get_string(1).strip_edges() if m else ""


static func _attr(tag: String, name: String) -> String:
	var m := HtmlText._re("(?is)\\s%s\\s*=\\s*[\"']([^\"']*)[\"']" % name).search(tag)
	return m.get_string(1) if m else ""


static func _join(base: String, rel: String) -> String:
	var parts := PackedStringArray()
	for seg in ((base + "/" + rel) if base != "" else rel).split("/"):
		if seg == "" or seg == ".":
			continue
		if seg == "..":
			if parts.size() > 0:
				parts.remove_at(parts.size() - 1)
		else:
			parts.append(seg)
	return "/".join(parts)
