extends Control
## App shell: primary navigation in a left sidebar, secondary navigation
## (page tabs + actions) in the top bar, and the active page below. On narrow
## screens the sidebar becomes a drawer opened from a menu button.

const COMPACT_WIDTH := 820.0

var pages := {}
var current: Page
var compact := false

var _root: HBoxContainer
var _sidebar: PanelContainer
var _sidebar_sep: ColorRect
var _drawer: Control
var _scrim: ColorRect
var _drawer_tween: Tween
var _top_listen: Button
var _laid_out := false
var _nav_buttons := {}
var _nav_group := ButtonGroup.new()
var _continue_box: Control
var _continue_key := ""  # book id and chapter the Continue card shows
var _listening_box: Control
var _bridge_row: VBoxContainer
var _update_box: VBoxContainer
var _topbar: PanelContainer
var _top_rows: VBoxContainer
var _host: Control
var _toast_box: VBoxContainer
var _sidebar_style: StyleBoxFlat

## Screen edges covered by the camera hole or system bars, in UI units (x left,
## y top, z right, w bottom). The background still runs under them; controls stay out.
var _insets := Vector4.ZERO
var _cutouts: Array[Rect2] = []  # camera holes, in UI units
var _bar_span := Vector2(-1, -1)  # top bar x and width the camera-hole fit was made for

const TOP_ROW_HEIGHT := 60.0
const HOLE_PAD := 8.0  # space kept between the camera hole and the buttons beside it


func _ready() -> void:
	get_tree().quit_on_go_back = false  # Android back: handled in _notification
	get_tree().node_added.connect(_on_node_added)
	_apply_scale()
	theme = UiTheme.build()
	var bg := Panel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_root = UI.hbox(0)
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	_sidebar = _build_sidebar()
	_root.add_child(_sidebar)
	_sidebar_style = (_sidebar.get_theme_stylebox("panel") as StyleBoxFlat).duplicate()
	_sidebar.add_theme_stylebox_override("panel", _sidebar_style)
	_sidebar_sep = ColorRect.new()
	_sidebar_sep.color = UiTheme.BORDER
	_sidebar_sep.custom_minimum_size.x = 1
	_root.add_child(_sidebar_sep)

	var right := UI.vbox(0)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(right)
	_topbar = UI.panel("Topbar")
	_top_rows = UI.vbox(0)
	_topbar.add_child(_top_rows)
	right.add_child(_topbar)
	_topbar.item_rect_changed.connect(_on_topbar_moved)
	_host = Control.new()
	_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_host.clip_contents = true
	right.add_child(_host)

	_drawer = Control.new()
	_drawer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_drawer.hide()
	add_child(_drawer)
	_scrim = ColorRect.new()
	_scrim.color = Color(0, 0, 0, 0.55)
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed:
			close_drawer())
	_drawer.add_child(_scrim)

	_toast_box = UI.vbox(8)
	_toast_box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_toast_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_toast_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_toast_box)

	for key in ["library", "browse", "web", "updates", "settings", "reader"]:
		var page: Page
		match key:
			"library": page = LibraryPage.new()
			"browse": page = BrowsePage.new()
			"updates": page = UpdatesPage.new()
			"settings": page = SettingsPage.new()
			"reader": page = ReaderPage.new()
			"web": page = WebPage.new()
		page.main = self
		page.name = key.capitalize()
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		page.hide()
		page.header_changed.connect(_rebuild_topbar)
		_host.add_child(page)
		pages[key] = page

	Library.changed.connect(_refresh_continue)
	# Reading doesn't emit `changed`, so also redraw when the card would show another book or chapter.
	Library.progress_changed.connect(_on_progress_changed)
	Plugins.status_changed.connect(_refresh_bridge)
	Plugins.changed.connect(_refresh_bridge)
	Plugins.message.connect(toast)
	UpdateCheck.changed.connect(_refresh_update)
	Speech.state_changed.connect(func(_p): _refresh_listening())
	Speech.paragraph_started.connect(func(_i): _refresh_listening())
	get_viewport().size_changed.connect(_on_resize)
	if OS.has_feature("android"):
		# The insets change without a resize when Android applies fullscreen
		# after start-up, so check now and then too. It's a cheap call.
		var t := Timer.new()
		t.wait_time = 0.5
		t.timeout.connect(_update_safe_area)
		add_child(t)
		t.start()
	_update_safe_area(true)
	_on_resize()
	navigate("library")
	_refresh_continue()
	_refresh_bridge()
	_refresh_update()

	if "--selftest" in OS.get_cmdline_user_args():
		add_child(load("res://scripts/dev/selftest.gd").new())
	if Array(OS.get_cmdline_user_args()).any(func(a): return a.begins_with("--plugintest=")):
		add_child(load("res://scripts/dev/plugintest.gd").new())
	if Array(OS.get_cmdline_user_args()).any(func(a): return a.begins_with("--synctest=")):
		add_child(load("res://scripts/dev/synctest.gd").new())


# A ScrollContainer only drag-scrolls on touch when the touch reaches it, but
# buttons, panels and cards stop it first. Let those pass the touch up to the
# scroll instead; buttons cancel their press once the scroll starts. Text
# fields, sliders and selectable text keep their own drags.
func _on_node_added(node: Node) -> void:
	if node is Control:
		_let_scroll_through.call_deferred(node)  # after the builder has set it up


func _let_scroll_through(node) -> void:  # untyped: the node may be freed by now
	if not is_instance_valid(node):
		return
	var c := node as Control
	if c.mouse_filter != Control.MOUSE_FILTER_STOP:
		return
	if c is ScrollContainer or c is LineEdit or c is TextEdit or c is Slider:
		return
	if c is RichTextLabel and (c as RichTextLabel).selection_enabled:
		return
	var p := c.get_parent()
	while p and not p is ScrollContainer:
		p = p.get_parent()
	if not p:
		return
	c.mouse_filter = Control.MOUSE_FILTER_PASS
	if c is BaseButton:
		# Option/menu buttons open on press, which would fire on every swipe.
		(c as BaseButton).action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE


func _apply_scale() -> void:
	var s := 1.0
	if OS.has_feature("mobile"):
		s = clampf(snappedf(DisplayServer.screen_get_dpi() / 160.0, 0.25), 1.0, 4.0)
	else:
		s = DisplayServer.screen_get_scale()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ui-scale="):
			s = arg.get_slice("=", 1).to_float()
	get_window().content_scale_factor = s


# --- navigation --------------------------------------------------------------

func navigate(key: String) -> void:
	var page: Page = pages[key]
	close_drawer()
	if current == page:
		return
	if current:
		current.on_hidden()
		current.hide()
	current = page
	page.show()
	var nav := page.nav_key() if page.nav_key() != "" else key
	if _nav_buttons.has(nav):
		_nav_buttons[nav].button_pressed = true
	page.select_tab(page.tab)
	_rebuild_topbar()
	page.on_shown()
	_refresh_listening()


func open_reader(book_id: String, chapter := -1) -> void:
	var reader: ReaderPage = pages.reader
	reader.tab = 0
	reader.open_book(book_id, chapter)
	if current == reader:
		_rebuild_topbar()
	else:
		navigate("reader")


## Updates → Saved searches.
func open_saved_searches() -> void:
	var updates: Page = pages.updates
	updates.tab = UpdatesPage.SEARCHES_TAB
	if current == updates:
		updates.select_tab(updates.tab)
		_rebuild_topbar()
	else:
		navigate("updates")


func open_plugin_settings() -> void:
	var settings: Page = pages.settings
	settings.tab = SettingsPage.PLUGINS_TAB
	if current == settings:
		settings.select_tab(settings.tab)
		_rebuild_topbar()
	else:
		navigate("settings")


func web_available() -> bool:
	return WebPage.available()


## Show a URL in the built-in browser (falls back to the system browser).
func open_web(url: String) -> void:
	if not web_available():
		OS.shell_open(url)
		return
	navigate("web")
	pages.web.open_url(url)


func toast(message: String, kind := "info") -> void:
	var color: Color = {"info": UiTheme.ACCENT, "ok": UiTheme.GOOD, "warn": UiTheme.WARN, "error": UiTheme.BAD}.get(kind, UiTheme.ACCENT)
	var row := UI.hbox(10, [UI.icon("check" if kind == "ok" else "info", color, 18)])
	var l := UI.label(message, "", true)
	l.custom_minimum_size.x = 300
	row.add_child(l)
	var p := UI.panel("Card", row)
	p.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SURFACE_2, 12, UiTheme.BORDER, 1, Vector4(14, 12, 16, 12)))
	_toast_box.add_child(p)
	var tw := create_tween()
	tw.tween_interval(4.0)
	tw.tween_property(p, "modulate:a", 0.0, 0.4)
	tw.tween_callback(p.queue_free)


# --- sidebar (primary navigation) --------------------------------------------

func _build_sidebar() -> PanelContainer:
	var side := UI.panel("Sidebar")
	side.custom_minimum_size.x = 236
	var col := UI.vbox(4)
	side.add_child(col)

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
	if web_available():
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
	b.pressed.connect(navigate.bind(key))
	_nav_buttons[key] = b
	col.add_child(b)


func _on_progress_changed(_id: String) -> void:
	if _continue_key_of(Library.last_read()) != _continue_key:
		_refresh_continue()


func _continue_key_of(book: Dictionary) -> String:
	return "" if book.is_empty() else "%s:%d" % [book.id, book.progress.chapter]


func _refresh_continue() -> void:
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
	info.add_child(UI.label("%d of %d  ·  %d%%" % [book.progress.chapter + 1, book.chapters.size(), int(Library.progress_ratio(book) * 100)], "Small"))
	var bar := UI.progress(Library.progress_ratio(book), 3)
	info.add_child(bar)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := UI.hbox(10, [cover, info])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := UI.margin(row, 12, 12, 12, 12)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(m)
	card.pressed.connect(func(): close_drawer(); open_reader(book.id))
	_continue_box.add_child(card)


## Page key whose view shows the active read-aloud, or "" when nothing is playing.
func _listening_page() -> String:
	if not Speech.playing or not pages.has(Speech.source_owner):
		return ""
	return Speech.source_owner


func _listening_visible() -> bool:
	var key := _listening_page()
	return key != "" and current == pages[key] and (key != "reader" or current.tab == 0)


## Jump to the view where text-to-speech is reading.
func show_listening() -> void:
	var key := _listening_page()
	if key == "":
		return
	navigate(key)
	if key == "reader" and current.tab != 0:
		current.select_tab(0)
		_rebuild_topbar()
	if current.has_method("reveal_speech"):
		current.reveal_speech.call_deferred()
	_refresh_listening()


func _listening_title() -> String:
	match _listening_page():
		"reader":
			var r: ReaderPage = pages.reader
			return "%s  ·  Ch. %d" % [r.book.get("title", "Reader"), r.chapter + 1]
		"web":
			var info: Dictionary = pages.web.info
			for k in ["chapterTitle", "fictionTitle", "title"]:
				if str(info.get(k, "")) != "":
					return str(info[k])
			return "Web page"
	return ""


func _refresh_listening() -> void:
	if _listening_box == null:
		return
	UI.clear(_listening_box)
	var show := _listening_page() != "" and not _listening_visible()
	if is_instance_valid(_top_listen):
		_top_listen.visible = show
	if not show:
		return
	var title := _listening_title()
	var tip := "%s: %s — click to jump there" % ["Paused" if Speech.paused else "Listening", title]
	if is_instance_valid(_top_listen):
		_top_listen.tooltip_text = tip
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
	card.pressed.connect(func(): close_drawer(); show_listening())
	_listening_box.add_child(UI.margin(card, 0, 6, 0, 0))


## Notice above Settings when GitHub has a newer release; opens it in the system browser.
func _refresh_update() -> void:
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
	b.pressed.connect(func(): close_drawer(); OS.shell_open(UpdateCheck.latest_url))
	_update_box.add_child(UI.margin(b, 0, 6, 0, 6))


## Status of plugins that run a helper (e.g. a local server), above Settings.
func _refresh_bridge() -> void:
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


func _on_resize() -> void:
	_update_safe_area()
	var w := get_viewport_rect().size.x
	var c := w < COMPACT_WIDTH
	if _drawer.visible:
		_sidebar.size.x = _drawer_width()
	if c == compact and _laid_out:
		return
	_laid_out = true
	compact = c
	close_drawer(false)
	# Wide: sidebar sits in the layout. Compact: it lives in the drawer overlay.
	var parent: Control = _drawer if compact else _root
	if _sidebar.get_parent() != parent:
		_sidebar.get_parent().remove_child(_sidebar)
		parent.add_child(_sidebar)
		if not compact:
			_sidebar.set_anchors_preset(Control.PRESET_TOP_LEFT)
			_root.move_child(_sidebar, 0)
	_sidebar_sep.visible = not compact
	(_topbar.get_theme_stylebox("panel") as StyleBoxFlat).content_margin_left = 8 if compact else 28
	for p in pages.values():
		p.set_compact(compact)
	_rebuild_topbar()


# --- safe area (Android camera hole and system bars) -------------------------

func _update_safe_area(force := false) -> void:
	var insets := Vector4.ZERO
	var cutouts: Array[Rect2] = []
	var s := get_window().content_scale_factor
	# On desktops the "safe area" is the screen minus the taskbar, not the window's.
	if OS.has_feature("android"):
		var win := Vector2(DisplayServer.window_get_size())
		var safe := Rect2(DisplayServer.get_display_safe_area())
		insets = Vector4(safe.position.x, safe.position.y, win.x - safe.end.x, win.y - safe.end.y) / s
		for r in DisplayServer.get_display_cutouts():
			cutouts.append(Rect2(r.position / s, r.size / s))
	# Desktop testing: --fake-cutout=x,y,w,h (UI units) acts like a camera hole there.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fake-cutout="):
			var v := arg.get_slice("=", 1).split_floats(",")
			if v.size() == 4:
				cutouts = [Rect2(v[0], v[1], v[2], v[3])]
				insets.y = maxf(insets.y, v[1] + v[3])
	insets = insets.max(Vector4.ZERO)
	if not force and insets.is_equal_approx(_insets) and cutouts == _cutouts:
		return
	_insets = insets
	_cutouts = cutouts
	_root.offset_left = insets.x
	_root.offset_right = -insets.z
	_root.offset_bottom = -insets.w
	_sidebar_style.content_margin_top = 16 + insets.y
	_toast_box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_toast_box.position -= Vector2(24 + insets.z, 24 + insets.w)
	_bar_span = Vector2(-1, -1)
	if not force:
		_rebuild_topbar()


## Camera holes at the top edge of the screen.
func _top_holes() -> Array[Rect2]:
	var holes: Array[Rect2] = []
	for c in _cutouts:
		if c.position.y <= 4 and c.size.y > 0:
			holes.append(c)
	return holes


func _on_topbar_moved() -> void:
	if _top_holes().is_empty():
		return
	if Vector2(_topbar.global_position.x, _topbar.size.x) != _bar_span:
		_rebuild_topbar.call_deferred()


## Puts the top bar's first row at the very top of the screen, with its buttons
## split around the camera hole, or below the hole when they don't fit beside it.
## The title then gets its own full-width line under the buttons, unless
## `title_up` and all of it fits beside the hole.
func _place_top_row(row: HBoxContainer, title: Control, title_up := false) -> void:
	var style := _topbar.get_theme_stylebox("panel") as StyleBoxFlat
	var holes := _top_holes()
	var depth := 0.0
	for h in holes:
		depth = maxf(depth, h.end.y)
	# Only when the hole is all that's up there: a visible status bar can't be dodged.
	if holes.is_empty() or _insets.y > depth + 1 or not _split_row(row, title, holes, style, title_up):
		style.content_margin_top = _insets.y
	else:
		style.content_margin_top = maxf(0.0, depth - TOP_ROW_HEIGHT)


func _split_row(row: HBoxContainer, title: Control, holes: Array[Rect2], style: StyleBoxFlat, title_up: bool) -> bool:
	_bar_span = Vector2(_topbar.global_position.x, _topbar.size.x)
	var row_x := _bar_span.x + style.content_margin_left
	var row_w := _bar_span.y - style.content_margin_left - style.content_margin_right
	if row_w <= 0:
		return false  # not laid out yet; _on_topbar_moved comes back once it is
	var x0 := INF
	var x1 := -INF
	for h in holes:
		x0 = minf(x0, h.position.x - row_x - HOLE_PAD)
		x1 = maxf(x1, h.end.x - row_x + HOLE_PAD)
	if x1 <= 0 or x0 >= row_w:
		return true  # the hole is beside the row, not over it
	x0 = maxf(x0, 0.0)
	x1 = minf(x1, row_w)

	var items: Array = row.get_children()
	var sep := float(row.get_theme_constant("separation"))
	var slot := items.find(title)
	# The title may stay in the row when all of it fits beside the hole.
	var best := -1
	if slot >= 0 and title_up:
		var full := _full_width(title)
		var old_min: float = title.custom_minimum_size.x
		title.custom_minimum_size.x = full
		best = _hole_slot(items, sep, x0, row_w - x1, slot + 1)
		title.custom_minimum_size.x = old_min
		if best > slot:  # title on the menu button's side of the hole
			title.custom_minimum_size.x = full
		else:
			best = -1
	if best < 0:
		# Otherwise only the buttons go up there and the title gets its own line.
		# Empty space takes its place, so the buttons keep to the ends of the row.
		if slot >= 0:
			items[slot] = UI.spacer()
		best = _hole_slot(items, sep, x0, row_w - x1, maxi(slot, 0))
		if best < 0:
			if slot >= 0:
				items[slot].free()
			return false
		if title:
			_title_below(row, title)

	var left_box := UI.hbox(int(sep))
	left_box.custom_minimum_size.x = x0
	var right_box := UI.hbox(int(sep))
	right_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var left_fills := false
	var right_fills := false
	for i in items.size():
		var c: Control = items[i]
		if c.get_parent() == row:
			row.remove_child(c)
		var fills := (c.size_flags_horizontal & Control.SIZE_EXPAND) != 0
		if i < best:
			left_box.add_child(c)
			left_fills = left_fills or fills
		else:
			right_box.add_child(c)
			right_fills = right_fills or fills
	if not left_fills:
		left_box.add_child(UI.spacer())
	if not right_fills:
		var sp := UI.spacer()
		right_box.add_child(sp)
		right_box.move_child(sp, 0)  # keeps the actions at the right edge
	var gap := Control.new()
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gap.custom_minimum_size.x = x1 - x0
	row.add_theme_constant_override("separation", 0)
	for c in [left_box, gap, right_box]:
		row.add_child(c)
	return true


## Where in `items` the hole can go so everything before it fits in `left`
## and everything after in `right`, or -1. Picks the place nearest `near`.
func _hole_slot(items: Array, sep: float, left: float, right: float, near: int) -> int:
	var widths: Array[float] = []
	for c: Control in items:
		widths.append(c.get_combined_minimum_size().x)
	var best := -1
	for k in items.size() + 1:
		if _span(widths.slice(0, k), sep) > left or _span(widths.slice(k), sep) > right:
			continue
		if best < 0 or absi(k - near) < absi(best - near):
			best = k
	return best


## How wide the title is with none of its text cut off.
static func _full_width(title: Control) -> float:
	if title is Label:
		var font := title.get_theme_font("font")
		var size := title.get_theme_font_size("font_size")
		return ceilf(font.get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	return title.get_combined_minimum_size().x


## Gives the title its own full-width line under the button row.
func _title_below(row: HBoxContainer, title: Control) -> void:
	row.remove_child(title)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_stretch_ratio = 1.0
	if title is Label:
		title.custom_minimum_size.x = 0
	var line := UI.margin(title, 8, 0, 8, 4)
	_top_rows.add_child(line)
	_top_rows.move_child(line, row.get_index() + 1)


static func _span(widths: Array, sep: float) -> float:
	if widths.is_empty():
		return 0.0
	var total := sep * (widths.size() - 1)
	for w in widths:
		total += w
	return total


# --- drawer (compact layout) -------------------------------------------------

func _drawer_width() -> float:
	return minf(280.0, get_viewport_rect().size.x * 0.82)


func open_drawer() -> void:
	if not compact or _drawer.visible:
		return
	var w := _drawer_width()
	_sidebar.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_sidebar.size = Vector2(w, _drawer.size.y)
	_sidebar.position.x = -w
	_scrim.modulate.a = 0.0
	_drawer.show()
	if _drawer_tween:
		_drawer_tween.kill()
	_drawer_tween = create_tween().set_parallel().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_drawer_tween.tween_property(_sidebar, "position:x", 0.0, 0.22)
	_drawer_tween.tween_property(_scrim, "modulate:a", 1.0, 0.22)


func close_drawer(animate := true) -> void:
	if _drawer == null or not _drawer.visible:
		return
	if _drawer_tween:
		_drawer_tween.kill()
	if not animate:
		_drawer.hide()
		return
	_drawer_tween = create_tween().set_parallel().set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	_drawer_tween.tween_property(_sidebar, "position:x", -_sidebar.size.x, 0.18)
	_drawer_tween.tween_property(_scrim, "modulate:a", 0.0, 0.18)
	_drawer_tween.chain().tween_callback(_drawer.hide)


# --- top bar (secondary navigation) ------------------------------------------

func _rebuild_topbar() -> void:
	if current == null:
		return
	UI.clear(_top_rows)
	_top_listen = null
	var row := UI.hbox(14)
	row.custom_minimum_size.y = TOP_ROW_HEIGHT
	if compact:
		var menu := UI.icon_button("menu", "Menu", open_drawer, 22)
		menu.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(menu)
		row.add_theme_constant_override("separation", 6)
	if current.has_back():
		var back := UI.icon_button("arrow_left", "Back", current.go_back)
		back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(back)
	var title_fills := false
	var title_ctl: Control
	var custom_title := current.title_control()
	if custom_title:
		custom_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(custom_title)
		title_ctl = custom_title
	else:
		var title := UI.label(current.page_title(), "H2")
		title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if compact:
			# The tabs get their own row below, so the title can use all the
			# space up to the action buttons.
			title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			title.clip_text = true
			title_fills = true
		elif current.has_back():
			title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			title.custom_minimum_size.x = 160
			title.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			title.size_flags_stretch_ratio = 0.5
			title.clip_text = true
		row.add_child(title)
		title_ctl = title

	var tabs_row := UI.hbox(22)
	var group := ButtonGroup.new()
	var names := current.tabs()
	for i in names.size():
		var b := Button.new()
		b.text = names[i]
		b.theme_type_variation = "TabButton"
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.button_pressed = i == current.tab
		b.pressed.connect(func(): current.select_tab(i); _refresh_listening())
		tabs_row.add_child(b)

	var actions := UI.hbox(6)
	actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if compact:
		# The sidebar's "now listening" card is hidden in the drawer, so offer
		# a jump button here instead.
		_top_listen = UI.icon_button("headphones", "", show_listening)
		_top_listen.icon = Icons.get_icon("headphones", Color.WHITE, 20)
		for c in ["icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
			_top_listen.add_theme_color_override(c, UiTheme.ACCENT)
		actions.add_child(_top_listen)
	current.build_actions(actions)

	if compact:
		if not title_fills:
			row.add_child(UI.spacer())
		row.add_child(actions)
		_top_rows.add_child(row)
		if names.size() > 0:
			var sc := ScrollContainer.new()
			sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
			sc.add_child(tabs_row)
			sc.custom_minimum_size.y = 48
			tabs_row.add_theme_constant_override("separation", 18)
			for b in tabs_row.get_children():
				b.add_theme_stylebox_override("normal", UiTheme.box(Color.TRANSPARENT, 0, Color.TRANSPARENT, 0, Vector4(2, 10, 2, 10)))
			_top_rows.add_child(sc)
		# A lone menu button up there looks lost, so the title joins it. With a
		# back button (e.g. an open book) the buttons fill the strip well enough.
		_place_top_row(row, title_ctl, not current.has_back())
	else:
		if names.size() > 0:
			var sep := ColorRect.new()
			sep.color = UiTheme.BORDER
			sep.custom_minimum_size = Vector2(1, 22)
			sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(sep)
		row.add_child(tabs_row)
		row.add_child(UI.spacer())
		row.add_child(actions)
		_top_rows.add_child(row)
		_place_top_row(row, title_ctl)
	_refresh_listening()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _drawer.visible:
		close_drawer()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") and current and current.has_back():
		current.go_back()
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if _drawer.visible:
			close_drawer()
			return
		if current and current.has_back():
			current.go_back()
			return
		# Leaving the app: run the same path as closing the window, so Sync can
		# upload pending changes before quitting.
		get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
		if get_tree().auto_accept_quit:
			get_tree().quit()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_update_safe_area()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		Speech.stop()
		Plugins.shutdown_all()
