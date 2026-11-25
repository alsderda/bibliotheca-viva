class_name ReaderDetails
extends RefCounted
## The reader's Details tab: the book's cover, facts and actions, and the dialogs they
## open. The ReaderPage keeps the tabs and the text view; this helper builds its own
## view and calls back into the page to rerender and to add its dialogs.

var page: ReaderPage
var view: Control
var _epub_dialog: FileDialog
var _cover_dialog: FileDialog


func _init(p: ReaderPage) -> void:
	page = p


func build_view() -> void:
	view = Control.new()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.add_child(view)


func build() -> void:
	UI.clear(view)
	var row := UI.hbox(32) if not page.compact else UI.vbox(20)
	var cover := CoverView.new()
	cover.radius = 12
	cover.custom_minimum_size = Vector2(200, 300) if not page.compact else Vector2(140, 210)
	cover.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cover.set_book(page.book)
	row.add_child(cover)
	var col := UI.vbox(10)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var t := UI.label(page.book.title, "H1", true)
	t.add_theme_font_override("font", UiTheme.serif_bold)
	t.add_theme_font_size_override("font_size", 30)
	col.add_child(t)
	if page.book.author != "":
		col.add_child(UI.label("by " + page.book.author, "Muted"))
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 6)
	chips.add_theme_constant_override("v_separation", 6)
	chips.add_child(UI.chip(BookStatus.kind_label(page.book), UiTheme.ACCENT))
	chips.add_child(UI.chip(BookStatus.source_name(page.book)))
	if page.book.get("dropped", false):
		chips.add_child(UI.chip("Dropped", UiTheme.BAD))
	elif BookStatus.is_finished(page.book):
		chips.add_child(UI.chip("Finished", UiTheme.GOOD))
	if BookStatus.is_favorite(page.book):
		chips.add_child(UI.chip("Favorite", UiTheme.ACCENT))
	if BookStatus.is_archived(page.book):
		chips.add_child(UI.chip("Archived", UiTheme.MUTED))
	for tag in page.book.get("tags", []):
		var tb := UI.button(tag, "", "ChipButton", func(): page.main.pages.library.show_tag(tag), UiTheme.MUTED)
		tb.tooltip_text = "Show the books tagged “%s”" % tag
		chips.add_child(tb)
	col.add_child(UI.margin(chips, 0, 4, 0, 8))
	if page.book.get("possible_gap", false):
		var gap := UI.label("Some new chapters may be missing. Open the book in the Web tab to fill them in.", "Small", true)
		gap.add_theme_color_override("font_color", UiTheme.WARN)
		col.add_child(gap)
	var stats := HFlowContainer.new()  # wraps on narrow (phone) screens
	stats.add_theme_constant_override("h_separation", 28)
	stats.add_theme_constant_override("v_separation", 14)
	stats.add_child(_stat("Chapters", str(page.book.chapters.size())))
	stats.add_child(_stat("Progress", "%d%%" % int(BookStatus.progress_ratio(page.book) * 100)))
	stats.add_child(_stat("Last read", UI.relative_time(page.book.last_read)))
	if page.book.kind == "web":
		stats.add_child(_stat("Downloaded", str(Library.cached_count(page.book.id))))
	var words := Library.saved_words(page.book)
	var total := int(page.book.get("total_words", 0))
	if words.chapters > 0 or total > 0:
		var w := _stat("Words", short_count(words.words) + (" / " + short_count(total) if total > 0 else ""))
		w.tooltip_text = "%s words in %d saved chapter(s)%s" % [grouped(words.words), words.chapters,
			", %s in the whole book (from the site)" % grouped(total) if total > 0 else ""]
		stats.add_child(w)
	col.add_child(stats)
	if page.book.synopsis != "":
		col.add_child(UI.margin(UI.label("About", "H3"), 0, 14, 0, 0))
		var syn := UI.label(page.book.synopsis, "", true)
		syn.add_theme_color_override("font_color", UiTheme.MUTED)
		syn.add_theme_constant_override("line_spacing", 4)
		col.add_child(syn)
	var buttons := HFlowContainer.new()  # wraps on narrow (phone) screens
	buttons.add_theme_constant_override("h_separation", 10)
	buttons.add_theme_constant_override("v_separation", 10)
	buttons.add_child(UI.button("Read", "book", "PrimaryButton", func(): page.main.pages.reader.select_tab(0); page.header_changed.emit()))
	if not Library.editable_fields(page.book).is_empty():
		var edit := UI.button("Edit details", "pencil", "", _edit_details)
		if Library.is_file_book(page.book):
			edit.tooltip_text = "Change the title, author, tags and description"
		else:
			edit.tooltip_text = "Change the title and tags shown for this book"
		buttons.add_child(edit)
	var change := UI.button("Change cover", "image", "", _pick_cover)
	change.tooltip_text = "Use an image file (PNG, JPEG or WebP) as this book's cover"
	buttons.add_child(change)
	if page.book.url != "":
		buttons.add_child(UI.button("Open website", "external", "", func(): OS.shell_open(page.book.url)))
	if page.book.kind == "web":
		var fill := UI.button("Add chapters from EPUB", "import", "", _pick_epub)
		fill.tooltip_text = "Fill in chapters that aren't downloaded from an EPUB of this book, e.g. one saved with WebToEpub"
		buttons.add_child(fill)
	elif Library.is_file_book(page.book):
		var more := UI.button("Add chapters from EPUB", "import", "", _pick_epub)
		more.tooltip_text = "Add the new chapters of a later EPUB of this book to its end, e.g. the latest chapters of a serial. Chapters it already has are skipped."
		buttons.add_child(more)
	var favorite: bool = BookStatus.is_favorite(page.book)
	var fav := UI.button("Unfavorite" if favorite else "Favorite", "star_fill" if favorite else "star", "", _toggle_favorite)
	fav.tooltip_text = "Remove this book from the Favorites tab" if favorite \
		else "Also show this book in the library's Favorites tab"
	buttons.add_child(fav)
	var archived: bool = BookStatus.is_archived(page.book)
	var arch := UI.button("Unarchive" if archived else "Archive", "archive", "", _toggle_archived)
	arch.tooltip_text = "Put this book back in the library's other tabs" if archived \
		else "Move this book to the library's Archive tab, out of Reading, the other tabs and Updates (a favorite stays in Favorites). It's only checked for new chapters from its chapter list."
	buttons.add_child(arch)
	var dropped: bool = page.book.get("dropped", false)
	var drop := UI.button("Undo drop" if dropped else "Mark as dropped", "refresh" if dropped else "x", "", _toggle_dropped)
	drop.tooltip_text = "Show this book in the Reading tab again" if dropped \
		else "Hide this book from the Reading tab until you open it again"
	buttons.add_child(drop)
	var del := UI.button("Delete book", "trash", "GhostButton", _confirm_delete, UiTheme.BAD)
	del.add_theme_color_override("font_color", UiTheme.BAD)
	del.tooltip_text = "Remove this book and its downloaded chapters from the library"
	buttons.add_child(del)
	col.add_child(UI.margin(buttons, 0, 16, 0, 0))
	row.add_child(col)
	var m := UI.margin(row, 40 if not page.compact else 20, 32, 40 if not page.compact else 20, 40)
	var s := UI.scroll(m)
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	view.add_child(s)


func _pick_epub() -> void:
	if _epub_dialog == null:
		_epub_dialog = FileDialog.new()
		_epub_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_epub_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_epub_dialog.use_native_dialog = true
		_epub_dialog.filters = PackedStringArray(["*.epub ; EPUB ebooks"])
		_epub_dialog.file_selected.connect(func(path):
			if page.book.get("kind", "") == "web":
				_fill_from_epub(path)
			else:
				_append_from_file(path))
		page.add_child(_epub_dialog)
	_epub_dialog.popup_centered_ratio(0.6)


func _pick_cover() -> void:
	if _cover_dialog == null:
		_cover_dialog = FileDialog.new()
		_cover_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_cover_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_cover_dialog.use_native_dialog = true
		_cover_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Images"])
		_cover_dialog.file_selected.connect(_set_cover)
		page.add_child(_cover_dialog)
	_cover_dialog.popup_centered_ratio(0.6)


func _edit_details() -> void:
	var id: String = page.book.id
	BookEditor.open(page.main, id, func():
		page.main.toast("Details saved", "ok")
		if page.book.get("id", "") == id:
			page.book = Library.get_book(id)
			build()
			page.header_changed.emit())


func _toggle_dropped() -> void:
	var dropped: bool = not page.book.get("dropped", false)
	Library.set_dropped(page.book.id, dropped)
	page.book = Library.get_book(page.book.id)
	build()
	page.main.toast("Marked as dropped" if dropped else "Back in your Reading list", "ok")


func _toggle_favorite() -> void:
	var favorite: bool = not BookStatus.is_favorite(page.book)
	Library.set_favorite(page.book.id, favorite)
	page.book = Library.get_book(page.book.id)
	build()
	page.main.toast("Added to favorites" if favorite else "Removed from favorites", "ok")


func _toggle_archived() -> void:
	var archived: bool = not BookStatus.is_archived(page.book)
	Library.set_archived(page.book.id, archived)
	page.book = Library.get_book(page.book.id)
	build()
	page.main.toast("Archived. Find it in the library's Archive tab" if archived else "Back in your library", "ok")


func _confirm_delete() -> void:
	var id: String = page.book.id
	ConfirmDialog.open(page.main, {
		"title": "Delete “%s”?" % page.book.title,
		"text": "This removes the book, its downloaded chapters, reading progress and bookmarks from the library, here and on your synced devices.",
		"icon": "trash", "confirm": "Delete", "confirm_icon": "trash", "danger": true,
	}, func():
		var b := Library.get_book(id)
		if b.is_empty():
			return
		if page.book.get("id", "") == id:
			if Speech.source_owner == "reader":
				Speech.stop()
			page.book = {}
			page._items = []
			page.main.navigate("library")
		Library.remove_book(id)
		page.main.toast("Deleted “%s”" % b.title))


func _set_cover(path: String) -> void:
	var id: String = page.book.id
	# read the bytes: works for Android's content:// URIs too
	var err := Library.set_cover_from_bytes(id, FileAccess.get_file_as_bytes(path))
	if err != "":
		page.main.toast(err, "error")
		return
	page.main.toast("Cover changed", "ok")
	if page.book.get("id", "") == id:
		page.book = Library.get_book(id)
		build()


## Adds the chapters of a later EPUB of an imported book (the next chapters of a
## serial) to its end. Asks first when the EPUB's title doesn't look like this book's.
func _append_from_file(path: String) -> void:
	var id: String = page.book.id
	var parsed := Library.read_file(path)
	if parsed.has("error"):
		page.main.toast(parsed.error, "error")
		return
	var fresh := Library.new_chapters_for(id, parsed)
	if fresh.is_empty():
		page.main.toast("This book already has all of the EPUB's chapters", "warn")
		return
	if not EpubMatch.same_series(page.book, parsed):
		ConfirmDialog.open(page.main, {
			"title": "Add chapters from a different book?",
			"text": "The EPUB is “%s”%s, not “%s”. Add its %d chapter(s) to the end of this book anyway?" % [
				parsed.title, " by " + parsed.author if parsed.get("author", "") != "" else "", page.book.title, fresh.size()],
			"icon": "import", "confirm": "Add chapters", "confirm_icon": "import",
		}, func(): _append_chapters(id, parsed, fresh))
		return
	_append_chapters(id, parsed, fresh)


func _append_chapters(id: String, parsed: Dictionary, fresh: Array) -> void:
	if Library.get_book(id).is_empty():
		return
	var skipped: int = parsed.chapters.size() - fresh.size()
	Library.append_chapters(id, parsed, fresh)
	page.main.toast("Added %d chapter(s)%s" % [fresh.size(), " (%d were already in it)" % skipped if skipped > 0 else ""], "ok")
	if page.book.get("id", "") == id:
		page.book = Library.get_book(id)
		build()


## Checks the site for new chapters first, so chapters the EPUB has that the
## chapter list doesn't yet can be filled too (if the site can't be reached, the
## chapters already listed are still filled).
func _fill_from_epub(path: String) -> void:
	var id: String = page.book.id
	var epub := Library.read_epub_for(id, path)
	if epub.has("error"):
		page.main.toast(epub.error, "error")
		return
	page.main.toast("Adding chapters from the EPUB…")
	await Sources.refresh(Library.get_book(id))
	if Library.get_book(id).is_empty():
		return
	var r := Library.fill_from_epub(id, epub)
	if page.book.get("id", "") == id:
		page.book = Library.get_book(id)
		build()
	if r.matched == 0:
		page.main.toast("None of the EPUB's chapters are in this book", "warn")
	elif r.filled == 0 and r.added == 0:
		page.main.toast("All %d chapter(s) the EPUB has are already downloaded" % r.matched, "ok")
	elif r.added == 0:
		page.main.toast("Added %d chapter(s) from the EPUB" % r.filled, "ok")
	else:
		page.main.toast("Added %d chapter(s) from the EPUB, %d of them no longer on the site" % [r.filled + r.added, r.added], "ok")


## 950, 8.4k, 84k, 1.2M
static func short_count(n: int) -> String:
	if n < 1000:
		return str(n)
	if n < 10000:
		return ("%.1fk" % (n / 1000.0)).replace(".0k", "k")
	if n < 1000000:
		return "%dk" % roundi(n / 1000.0)
	return ("%.1fM" % (n / 1000000.0)).replace(".0M", "M")


## 1234567 -> "1,234,567"
static func grouped(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out


func _stat(label: String, value: String) -> Control:
	var v := UI.vbox(2)
	v.add_child(UI.label(label.to_upper(), "Overline"))
	var l := UI.label(value, "H2")
	v.add_child(l)
	return v
