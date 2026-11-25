class_name NavSidebar
extends RefCounted
## The app's sidebar: the primary navigation buttons, and the cards above Settings
## for the Continue book, the read-aloud state, a newer release and plugin status.

const RAIL_WIDTH := 64.0

var nav_buttons := {}  # page key -> its nav button, so the app can show which page is open
var _main  # the app's main Control, which navigates and opens pages (untyped: it has no class_name)
var _nav_group := ButtonGroup.new()
var _continue_box: Control
var _continue_key := ""  # book id and chapter the Continue card shows
var _listening_box: Control
var _bridge_row: VBoxContainer
var _update_box: VBoxContainer


func _init(main) -> void:
	_main = main


## Builds the sidebar panel. The app puts it in its layout and keeps it.
func build() -> PanelContainer:
	var side := UI.panel("Sidebar")
	side.custom_minimum_size.x = 236
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(scroll)
	var col := UI.vbox(4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(col)

	var logo := PanelContainer.new()
	logo.add_theme_stylebox_override("panel", UiTheme.box(Color("#0284c7"), 9))
	logo.custom_minimum_size = Vector2(34, 34)
	var glyph := UI.icon("book", Color.WHITE, 20)
	glyph.custom_minimum_size = Vector2(34, 34)
	logo.add_child(glyph)
	var brand := UI.label("Bibliothéca-viva", "H3")
	brand.add_theme_font_size_override("font_size", 16)
	col.add_child(UI.margin(UI.hbox(10, [logo, brand]), 6, 0, 0, 18))

	_add_nav(col, "library", "Library", "library")
	_add_nav(col, "browse", "Browse", "compass")
	if _main.web_available():
		_add_nav(col, "web", "Web", "globe")
	_add_nav(col, "updates", "Updates", "bell")
	col.add_child(UI.spacer(false))

	_continue_box = UI.vbox(6)
	col.add_child(_continue_box)
	_listening_box = UI.vbox(0)
	col.add_child(_listening_box)
	_bridge_row = UI.vbox(4)
	col.add_child(UI.margin(_bridge_row, 10, 10, 6, 6))
	_update_box = UI.vbox(0)
	col.add_child(_update_box)
	_add_nav(col, "settings", "Settings", "settings")
	return side


func _add_nav(col: VBoxContainer, key: String, text: String, icon: String) -> void:
	var b := Button.new()
	b.text = text
	b.theme_type_variation = "NavButton"
	b.toggle_mode = true
	b.button_group = _nav_group
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.icon = Icons.get_icon(icon, Color.WHITE, 20)
	b.tooltip_text = text
	b.set_meta("label", text)
	b.pressed.connect(_main.navigate.bind(key))
	nav_buttons[key] = b
	col.add_child(b)


func on_progress_changed(_id: String) -> void:
	if _continue_key_of(Library.last_read()) != _continue_key:
		refresh_continue()


func _continue_key_of(book: Dictionary) -> String:
	return "" if book.is_empty() else "%s:%d" % [book.id, book.progress.chapter]


func refresh_continue() -> void:
	UI.clear(_continue_box)
	var book := Library.last_read()
	_continue_key = _continue_key_of(book)
	if book.is_empty():
		return
	var card := Button.new()
	card.focus_mode = Control.FOCUS_NONE
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.SURFACE, 12, UiTheme.BORDER, 1))
	card.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE_2, 12, UiTheme.BORDER, 1))
	card.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SURFACE_2, 12, UiTheme.BORDER, 1))
	card.custom_minimum_size = Vector2(0, 84)
	var cover := CoverView.new()
	cover.custom_minimum_size = Vector2(40, 60)
	cover.radius = 5
	cover.set_book(book)
	var info := UI.vbox(2)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(UI.label("CONTINUE", "Overline"))
	var t := UI.label(book.title, "H3")
	t.add_theme_font_size_override("font_size", 13)
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.custom_minimum_size.x = 110
	info.add_child(t)
	info.add_child(UI.label("%d of %d  ·  %d%%" % [book.progress.chapter + 1, book.chapters.size(), int(BookStatus.progress_ratio(book) * 100)], "Small"))
	var bar := UI.progress(BookStatus.progress_ratio(book), 3)
	info.add_child(bar)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := UI.hbox(10, [cover, info])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := UI.margin(row, 12, 12, 12, 12)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(m)
	card.pressed.connect(func(): _main.close_drawer(); _main.open_reader(book.id))
	_continue_box.add_child(card)


## Empties the slot above Settings where the "now listening" card goes.
func clear_listening() -> void:
	UI.clear(_listening_box)


## Adds the "now listening" card for the page being read aloud.
func add_listening_card(title: String, tip: String) -> void:
	var card := Button.new()
	card.focus_mode = Control.FOCUS_NONE
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.tooltip_text = tip
	card.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.SURFACE, 12, UiTheme.ACCENT, 1))
	card.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE_2, 12, UiTheme.ACCENT, 1))
	card.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SURFACE_2, 12, UiTheme.ACCENT, 1))
	card.custom_minimum_size = Vector2(0, 58)
	var icon := UI.icon("headphones", UiTheme.ACCENT, 20)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var info := UI.vbox(2)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(UI.label("PAUSED" if Speech.paused else "NOW LISTENING", "Overline"))
	var t := UI.label(title, "Small")
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.custom_minimum_size.x = 90
	info.add_child(t)
	var toggle := UI.icon_button("play" if Speech.paused else "pause", "Resume" if Speech.paused else "Pause", Speech.toggle, 18)
	toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := UI.hbox(10, [icon, info, toggle])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := UI.margin(row, 12, 8, 6, 8)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(m)
	card.pressed.connect(func(): _main.close_drawer(); _main.show_listening())
	_listening_box.add_child(UI.margin(card, 0, 6, 0, 0))


## Notice above Settings when GitHub has a newer release; opens it in the system browser.
func refresh_update() -> void:
	if _update_box == null:
		return
	UI.clear(_update_box)
	if UpdateCheck.latest == "":
		return
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.tooltip_text = "Open the release page in your browser"
	b.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.SURFACE, 12, UiTheme.ACCENT, 1))
	b.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SURFACE_2, 12, UiTheme.ACCENT, 1))
	b.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SURFACE_2, 12, UiTheme.ACCENT, 1))
	b.custom_minimum_size = Vector2(0, 52)
	var icon := UI.icon("download", UiTheme.ACCENT, 20)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var info := UI.vbox(2)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(UI.label("UPDATE AVAILABLE", "Overline"))
	var ver := UI.hbox(6, [UI.label("Version %s" % UpdateCheck.latest.trim_prefix("v"), "Small")])
	if UpdateCheck.latest_prerelease:
		var pre := UI.label("Pre-release", "Small")
		pre.add_theme_color_override("font_color", UiTheme.WARN)
		ver.add_child(pre)
	for c in ver.get_children():
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ver.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(ver)
	var row := UI.hbox(10, [icon, info, UI.icon("external", UiTheme.MUTED, 16)])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in row.get_children():
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		(c as Control).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var m := UI.margin(row, 12, 8, 12, 8)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(m)
	b.pressed.connect(func(): _main.close_drawer(); OS.shell_open(UpdateCheck.latest_url))
	_update_box.add_child(UI.margin(b, 0, 6, 0, 6))


## Status of plugins that run a helper (e.g. a local server), above Settings.
func refresh_bridge() -> void:
	UI.clear(_bridge_row)
	for p in Plugins.plugins:
		var st: Dictionary = p.status()
		if st.is_empty():
			continue
		var row := UI.hbox(8)
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(8, 8)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot.color = UiTheme.GOOD if st.get("ok", false) else UiTheme.FAINT
		row.add_child(dot)
		row.tooltip_text = "%s: %s" % [p.name, st.get("text", "")]
		row.add_child(UI.label(st.get("short", p.name), "Small"))
		_bridge_row.add_child(row)


## Rebuilds the rail buttons for the page now open: menu, back, tab picker, page actions and listening.
func rebuild_rail() -> void:
	UI.clear(_main._rail_box)
	_main._top_listen = null
	var menu: Button = _main.rail_button("menu", "Menu", _main.open_drawer)
	_main._rail_box.add_child(menu)
	if _main.current.has_back():
		_main._rail_box.add_child(_main.rail_button("arrow_left", "Back", _main.current.go_back))
	var names: PackedStringArray = _main.current.tabs()
	if not names.is_empty():
		_main._rail_box.add_child(_rail_tab_picker(names))
	_main._rail_box.add_child(UI.spacer(false))
	var actions := UI.hbox(0)
	_main.current.build_actions(actions)
	for c: Control in actions.get_children():
		actions.remove_child(c)
		c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		c.custom_minimum_size = c.custom_minimum_size.max(Vector2(40, 40))
		_main._rail_box.add_child(c)
	actions.free()
	_main.current.build_rail_extras(_main._rail_box)
	_main._top_listen = _main.rail_button("headphones", _main._listening_title(), _main.show_listening)
	_main._top_listen.icon = Icons.get_icon("headphones", UiTheme.ACCENT, 20)
	_main._top_listen.visible = _main._listen_button_wanted()
	_main._rail_box.add_child(_main._top_listen)


func _rail_tab_picker(names: PackedStringArray) -> Button:
	var selected := clampi(_main.current.tab, 0, names.size() - 1)
	var name := names[selected]
	var icons: PackedStringArray = _main.current.tab_icons()
	var icon := icons[selected] if icons.size() == names.size() else "list"
	var b := UI.button(name, icon, "GhostButton")
	b.custom_minimum_size = Vector2(RAIL_WIDTH - 8, 48)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.clip_text = true
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_font_size_override("font_size", 10)
	var normal := UiTheme.box(Color.TRANSPARENT, 8, Color.TRANSPARENT, 0, Vector4(2, 4, 2, 4))
	var hover := UiTheme.box(UiTheme.SURFACE_2, 8, Color.TRANSPARENT, 0, Vector4(2, 4, 2, 4))
	var selected_style := UiTheme.box(UiTheme.ACCENT_DIM, 8, Color.TRANSPARENT, 0, Vector4(2, 4, 2, 4))
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(state, normal if state == "normal" else hover if state == "hover" else selected_style)
	b.tooltip_text = name
	b.pressed.connect(func(): _show_tab_picker(b, names))
	return b


func _show_tab_picker(anchor: Control, names: PackedStringArray) -> void:
	var list := UI.vbox(2)
	list.custom_minimum_size.x = 220
	var title := UI.label(_main.current.page_title(), "H3")
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	list.add_child(title)
	var pop := Popover.show_for(anchor, list)
	var icons: PackedStringArray = _main.current.tab_icons()
	for i in names.size():
		var index := i
		var icon := icons[index] if icons.size() == names.size() else ""
		var choice := UI.button(names[index], icon, "GhostButton", func():
			pop.close()
			_main.current.select_tab(index)
			_main._refresh_listening()
			_main._rebuild_topbar())
		choice.alignment = HORIZONTAL_ALIGNMENT_LEFT
		choice.custom_minimum_size.y = 40
		list.add_child(choice)
