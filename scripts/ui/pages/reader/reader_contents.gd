class_name ReaderContents
extends RefCounted
## The reader's Contents tab: the book's chapter list, split into collapsible groups when
## it is long. The ReaderPage keeps the tabs and the text view; this helper builds its own
## view and reads the page's book and chapter.

var page: ReaderPage
var view: Control
var list: VBoxContainer
var open_groups := {}  # start index -> true for each expanded group
var _contents_book := ""  # book id open_groups belongs to


func _init(p: ReaderPage) -> void:
	page = p


func build_view() -> void:
	list = UI.vbox(2)
	var scroll := UI.scroll(UI.margin(list, 0, 20, 0, 40))
	view = UI.margin(scroll, 8 if page.compact else 24, 0, 8 if page.compact else 24, 0)
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	view.hide()
	page.add_child(view)


func build() -> void:
	UI.clear(list)
	var head := UI.hbox(10)
	head.add_child(UI.label("%d chapters" % page.book.chapters.size(), "H2"))
	if page.book.kind == "web":
		var cached := Library.cached_count(page.book.id)
		head.add_child(UI.chip("%d downloaded" % cached))
		head.add_child(UI.spacer())
		var check := UI.button("" if page.compact else "Check for new", "refresh", "", page._refresh_book)
		check.tooltip_text = "Check for new chapters"
		head.add_child(check)
	list.add_child(UI.margin(head, 6 if page.compact else 12, 0, 6 if page.compact else 12, 12))
	if page.book.get("id", "") != _contents_book:
		_contents_book = page.book.get("id", "")
		open_groups.clear()
	var titles := PackedStringArray()
	for ch in page.book.chapters:
		titles.append(ch.title)
	var groups := BookGroups.split(titles, int(Settings.get_value("contents_group_size")))
	if groups.is_empty():
		for i in page.book.chapters.size():
			list.add_child(_chapter_button(i))
		return
	for g in groups:
		if int(g.start) <= page.chapter and page.chapter < int(g.end):
			open_groups[int(g.start)] = true
	for g in groups:
		var box := UI.vbox(2)
		if open_groups.has(int(g.start)):
			_fill_group(box, int(g.start), int(g.end))
		else:
			box.hide()
		list.add_child(_group_header(g, box))
		list.add_child(box)


## One Contents chapter row: the title, muted once read, with a download badge for web books.
func _chapter_button(i: int) -> Button:
	var ch: Dictionary = page.book.chapters[i]
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.custom_minimum_size.y = 44
	var current_ch: bool = i == page.chapter
	var pad := Vector4(14, 10, 14, 10)
	b.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.ACCENT_DIM if current_ch else Color.TRANSPARENT, 8, Color.TRANSPARENT, 0, pad))
	b.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE_2, 8, Color.TRANSPARENT, 0, pad))
	b.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SURFACE_3, 8, Color.TRANSPARENT, 0, pad))
	b.add_theme_color_override("font_color", UiTheme.TEXT if (current_ch or i > page.book.progress.chapter or page.book.last_read == 0) else UiTheme.MUTED)
	b.text = "%d.   %s" % [i + 1, ch.title]
	if page.book.kind == "web":
		var have := Library.has_chapter(page.book.id, i)
		b.icon = Icons.get_icon("check" if have else "download", UiTheme.GOOD if have else UiTheme.FAINT, 16)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		b.tooltip_text = "Downloaded" if have else "Not downloaded yet"
	b.pressed.connect(func(): page.go_to_chapter(i); page.main.pages.reader.select_tab(0); page.header_changed.emit())
	return b


## A Contents group header: the group's label and chapter count, with a chevron
## showing whether its chapter list (built lazily) is expanded.
func _group_header(g: Dictionary, box: VBoxContainer) -> Button:
	var start := int(g.start)
	var end := int(g.end)
	var n := end - start
	var b := Button.new()
	b.set_meta("group_start", start)
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.custom_minimum_size.y = 44
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pad := Vector4(14, 10, 14, 10)
	b.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.SURFACE, 8, Color.TRANSPARENT, 0, pad))
	b.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE_2, 8, Color.TRANSPARENT, 0, pad))
	b.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SURFACE_3, 8, Color.TRANSPARENT, 0, pad))
	b.add_theme_font_override("font", UiTheme.sans_semibold)
	b.add_theme_color_override("font_color", UiTheme.TEXT)
	b.text = "%s  ·  %d %s" % [g.label, n, "chapter" if n == 1 else "chapters"]
	b.icon = Icons.get_icon("chev_down" if open_groups.has(start) else "chev_right", UiTheme.MUTED, 18)
	b.pressed.connect(func(): _toggle_group(b, box, start, end))
	return b


## Opens or closes a Contents group in place, so the list keeps its scroll position.
func _toggle_group(header: Button, box: VBoxContainer, start: int, end: int) -> void:
	if open_groups.has(start):
		open_groups.erase(start)
		box.hide()
		header.icon = Icons.get_icon("chev_right", UiTheme.MUTED, 18)
	else:
		open_groups[start] = true
		_fill_group(box, start, end)
		box.show()
		header.icon = Icons.get_icon("chev_down", UiTheme.MUTED, 18)


## Builds a group's chapter rows the first time it is shown, so opening
## Contents stays fast even with thousands of chapters.
func _fill_group(box: VBoxContainer, start: int, end: int) -> void:
	if box.get_child_count() > 0:
		return
	for i in range(start, end):
		box.add_child(_chapter_button(i))
