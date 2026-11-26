class_name ReaderSelection
extends RefCounted
## Selecting text in the reader: the right-click menu's rule and bookmark items,
## and on touch screens the long press and the selection bar over the text with
## its Copy, Bookmark and More actions.

var page: ReaderPage
const MENU_FIX_SPEECH := 100
const MENU_SKIP_SPEECH := 101
const MENU_REPLACE_TEXT := 102
const MENU_BOOKMARK := 103
const SEL_COPY := 200
const SEL_BOOKMARK := 201
const SEL_MORE := 202
const SEL_COPY_PARA := 203
var _menu_paragraph := -1        # paragraph the context menu was opened on
var _press_timer: Timer          # long-press on a paragraph (touch screens)
var _press_at := Vector2.ZERO
var _tap := false                # the current touch is still a plain tap
var _press_scroll := 0.0         # scroll position when the current touch began
var bar: SelectionBar           # touch selection pop-up over the text; the page puts it in the text view
var _sel_paragraph := -1         # paragraph the selection bar was opened on
var _sel_popup: PopupMenu        # the bar's "More" menu, if open


func _init(p: ReaderPage) -> void:
	page = p


func setup() -> void:
	var menu := page._text.get_menu()
	menu.add_separator()
	menu.add_item("Fix pronunciation of selection…", MENU_FIX_SPEECH)
	menu.add_item("Don't read selection aloud…", MENU_SKIP_SPEECH)
	menu.add_item("Replace selection in text…", MENU_REPLACE_TEXT)
	menu.add_separator()
	menu.add_item("Bookmark this paragraph…", MENU_BOOKMARK)
	menu.id_pressed.connect(_on_menu_item)
	menu.about_to_popup.connect(func():
		var has := page._text.get_selected_text().strip_edges() != ""
		for id in [MENU_FIX_SPEECH, MENU_SKIP_SPEECH, MENU_REPLACE_TEXT]:
			menu.set_item_disabled(menu.get_item_index(id), not has)
		var bi := menu.get_item_index(MENU_BOOKMARK)
		menu.set_item_disabled(bi, _menu_paragraph < 0)
		var marked := _menu_paragraph >= 0 and not Library.bookmark_at(page.book, page.chapter, _menu_paragraph).is_empty()
		menu.set_item_text(bi, "Edit bookmark…" if marked else "Bookmark this paragraph…"))
	page._text.gui_input.connect(_on_text_input)
	_press_timer = Timer.new()
	_press_timer.one_shot = true
	_press_timer.wait_time = 0.6
	_press_timer.timeout.connect(func():
		_tap = false
		# Off until the finger lifts: jitter of a held finger across a line edge
		# would otherwise select a line's worth of text under the bar.
		page._text.selection_enabled = false
		page._text.focus_mode = Control.FOCUS_CLICK
		show_bar(_press_at))
	page.add_child(_press_timer)


## Notes the paragraph under a right-click (for the menu). On touch screens a
## long press or a touch release after selecting pops up the selection bar,
## since there is no right-click.
func _on_text_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
		_menu_paragraph = _paragraph_at(e.position)
	elif e is InputEventScreenTouch:
		if e.pressed:
			_press_at = e.position
			_press_scroll = page._text.get_v_scroll_bar().value
			_tap = not e.double_tap
			hide_bar()
			if _tap:
				_press_timer.start()
		else:
			_press_timer.stop()
			var long_press := not page._text.selection_enabled
			if long_press:
				page._text.selection_enabled = true
				page._text.focus_mode = Control.FOCUS_CLICK
			# A press only moves the nearest end of an existing selection (the label
			# gets the emulated mouse press before this touch event), so without
			# this a touch screen could never dismiss a selection. After a long
			# press the label still holds what the jitter selected and brings it back.
			# A slow swipe both scrolls and selects; the selection is a side effect.
			var scrolled := absf(page._text.get_v_scroll_bar().value - _press_scroll) > 1.0
			if _tap or long_press or scrolled:
				page._text.deselect.call_deferred()
			else:
				_maybe_show_selection_bar.call_deferred(e.position)
	elif e is InputEventScreenDrag and e.position.distance_to(_press_at) > 12:
		_tap = false
		_press_timer.stop()


## Shows the selection bar after a touch release, once the label has caught up
## with the touch. Only when text ended up selected, so taps and scrolls do nothing.
func _maybe_show_selection_bar(anchor: Vector2) -> void:
	if page._text.get_selected_text().strip_edges() == "":
		return
	show_bar(anchor)


## Shows the selection bar at a touch point: Copy, Bookmark and More when text
## is selected, Bookmark and Copy paragraph on a long press with no selection.
func show_bar(anchor: Vector2) -> void:
	if page._items.is_empty():
		return
	var i := _paragraph_at(anchor)
	if i < 0:
		return
	_sel_paragraph = i
	bar.show_at(anchor, Rect2(Vector2.ZERO, page._read_stack.size),
		actions(page._text.get_selected_text().strip_edges() != "", _bookmarked(i)))


## Hides the selection bar and its More menu, if either is open.
func hide_bar() -> void:
	if is_instance_valid(bar):
		bar.hide()
	if is_instance_valid(_sel_popup):
		_sel_popup.hide()
		_sel_popup = null


## Whether paragraph i of this chapter already has a bookmark.
func _bookmarked(i: int) -> bool:
	return i >= 0 and not Library.bookmark_at(page.book, page.chapter, i).is_empty()


## The buttons for the touch selection bar: Copy, Bookmark and More with a
## selection; Bookmark and Copy paragraph without one.
static func actions(has_selection: bool, bookmarked: bool) -> Array:
	var mark := {"id": SEL_BOOKMARK, "text": "Edit bookmark" if bookmarked else "Bookmark",
		"icon": "bookmark_fill" if bookmarked else "bookmark"}
	if not has_selection:
		return [mark, {"id": SEL_COPY_PARA, "text": "Copy paragraph", "icon": "copy"}]
	return [{"id": SEL_COPY, "text": "Copy", "icon": "copy"}, mark,
		{"id": SEL_MORE, "text": "More", "icon": "more"}]


func on_action(id: int) -> void:
	match id:
		SEL_COPY:
			_copy_text(page._text.get_selected_text().strip_edges())
			page._text.deselect()
		SEL_COPY_PARA:
			_copy_text(_paragraph_plain(_sel_paragraph))
		SEL_BOOKMARK:
			page.bookmarks.edit_bookmark(_sel_paragraph)
		SEL_MORE:
			_show_more_menu()
			return
	hide_bar()


## Copies text to the clipboard, if there is any, and says so.
func _copy_text(s: String) -> void:
	if s == "":
		return
	DisplayServer.clipboard_set(s)
	page.main.toast("Copied.", "ok")


## The paragraph's shown text, without BBCode, for copying.
func _paragraph_plain(i: int) -> String:
	if i < 0 or i >= page._items.size():
		return ""
	return ReaderMarkup.visible_text(page._items[i].bb).strip_edges()


## The three selection rule actions as a pop-up, reusing the menu logic.
func _show_more_menu() -> void:
	hide_bar()
	var menu := PopupMenu.new()
	menu.add_item("Fix pronunciation of selection…", MENU_FIX_SPEECH)
	menu.add_item("Don't read selection aloud…", MENU_SKIP_SPEECH)
	menu.add_item("Replace selection in text…", MENU_REPLACE_TEXT)
	page.add_child(menu)
	_sel_popup = menu
	menu.id_pressed.connect(_on_menu_item)
	menu.popup_hide.connect(func(): menu.queue_free())
	var r := bar.get_global_rect()
	menu.popup(Rect2i(Vector2i(int(r.position.x), int(r.end.y + 4)), Vector2i.ZERO))


## The paragraph at a point in the text view, or -1.
func _paragraph_at(pos: Vector2) -> int:
	if page._items.is_empty():
		return -1
	var y := pos.y - page._text.get_theme_stylebox("normal").content_margin_top + page._text.get_v_scroll_bar().value
	var found := 0
	for i in page._items.size():
		if page._text.get_paragraph_offset(i) > y:
			break
		found = i
	return found


func _on_menu_item(id: int) -> void:
	if id == MENU_BOOKMARK:
		if _menu_paragraph >= 0:
			page.bookmarks.edit_bookmark(_menu_paragraph)
		return
	var sel := page._text.get_selected_text().strip_edges()
	if sel == "" or id < MENU_FIX_SPEECH:
		return
	var context := _paragraph_containing(sel)
	match id:
		MENU_FIX_SPEECH:
			page.open_rule_editor({"pattern": sel, "replace": sel, "scope": "tts", "whole_word": true, "book": page.book.id}, context)
		MENU_SKIP_SPEECH:
			page.open_rule_editor({"pattern": sel, "replace": " ", "scope": "tts", "book": page.book.id}, context)
		MENU_REPLACE_TEXT:
			page.open_rule_editor({"pattern": sel, "replace": "", "scope": "display", "book": page.book.id}, context)


func _paragraph_containing(text: String) -> String:
	for p in page._data.get("paragraphs", []):
		var plain := HtmlText.plain(p)
		if plain.find(text) != -1:
			return plain
	return text
