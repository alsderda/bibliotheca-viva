extends Control
## App shell: primary navigation in a left sidebar, secondary navigation in a
## top bar or short-landscape rail, and the active page below. On narrow screens
## the sidebar becomes a drawer opened from a menu button.

const COMPACT_WIDTH := 820.0
const RAIL_MAX_HEIGHT := 500.0

var pages := {}
var current: Page
var compact := false
var rail := false

var _root: HBoxContainer
var _sidebar: PanelContainer
var _sidebar_sep: ColorRect
var _drawer: Control
var _scrim: ColorRect
var _drawer_tween: Tween
var _top_listen: Button
var _laid_out := false
var _nav: NavSidebar
var _fit: TopBarFit
var _topbar: PanelContainer
var _top_rows: VBoxContainer
var _rail_scroll: ScrollContainer
var _rail_box: VBoxContainer
var _rail_sep: ColorRect
var _tab_strip: TabStrip
var _tab_strip_page: Page
var _host: Control
var _toast_box: VBoxContainer
var _sidebar_style: StyleBoxFlat
var _icon_generation := 0  # pause/resume count; a resume redraws icons only if no pause came after it


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
	_nav = NavSidebar.new(self)
	_fit = TopBarFit.new(self)
	_sidebar = _nav.build()
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
	_topbar.item_rect_changed.connect(_fit.on_topbar_moved)
	var content := UI.hbox(0)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(content)
	_rail_scroll = ScrollContainer.new()
	_rail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rail_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_rail_scroll.custom_minimum_size.x = NavSidebar.RAIL_WIDTH
	_rail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rail_scroll.hide()
	_rail_box = UI.vbox(2)
	_rail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rail_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var rail_panel := UI.panel("Sidebar", _rail_box)
	rail_panel.custom_minimum_size.x = NavSidebar.RAIL_WIDTH
	rail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rail_panel.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SIDEBAR, 0, Color.TRANSPARENT, 0, Vector4(4, 4, 4, 4)))
	_rail_scroll.add_child(rail_panel)
	content.add_child(_rail_scroll)
	_rail_sep = ColorRect.new()
	_rail_sep.color = UiTheme.BORDER
	_rail_sep.custom_minimum_size.x = 1
	_rail_sep.hide()
	content.add_child(_rail_sep)
	_host = Control.new()
	_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_host.clip_contents = true
	content.add_child(_host)

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

	Library.changed.connect(_nav.refresh_continue)
	# Reading doesn't emit `changed`, so also redraw when the card would show another book or chapter.
	Library.progress_changed.connect(_nav.on_progress_changed)
	Plugins.status_changed.connect(_nav.refresh_bridge)
	Plugins.changed.connect(_nav.refresh_bridge)
	Plugins.message.connect(toast)
	UpdateCheck.changed.connect(_nav.refresh_update)
	Speech.state_changed.connect(func(_p): _refresh_listening())
	Speech.paragraph_started.connect(func(_i): _refresh_listening())
	get_viewport().size_changed.connect(_on_resize)
	if OS.has_feature("android"):
		# The insets change without a resize when Android applies fullscreen
		# after start-up, so check now and then too. It's a cheap call.
		var t := Timer.new()
		t.wait_time = 0.5
		t.timeout.connect(_fit.update_safe_area)
		add_child(t)
		t.start()
	_fit.update_safe_area(true)
	_on_resize()
	navigate("library")
	_nav.refresh_continue()
	_nav.refresh_bridge()
	_nav.refresh_update()

	if Array(OS.get_cmdline_user_args()).any(func(a): return a.begins_with("--zzshot=")): add_child(load("res://scripts/dev/zz_shot.gd").new())
	if "--selftest" in OS.get_cmdline_user_args():
		add_child(load("res://scripts/dev/selftest.gd").new())
	if "--followcheck" in OS.get_cmdline_user_args() or "--followshots" in OS.get_cmdline_user_args():
		add_child(load("res://scripts/dev/follow_check.gd").new())
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


# Godot types through a hidden Android text box. Sometimes that box keeps
# Android's focus after no field is being edited any more, and then Android
# brings the keyboard up by itself each time the app comes back to the front.
# Godot's hide also hands that focus back to the game view, so hide the
# keyboard while the app goes to the background, unless a field is being typed in.
func _hide_stray_keyboard() -> void:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		return
	var f := get_viewport().gui_get_focus_owner()
	if (f is LineEdit or f is TextEdit) and f.is_visible_in_tree():
		return
	DisplayServer.virtual_keyboard_hide()


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
	AppLog.info("ui", "page " + key)
	page.show()
	var nav := page.nav_key() if page.nav_key() != "" else key
	if _nav.nav_buttons.has(nav):
		_nav.nav_buttons[nav].button_pressed = true
	page.select_tab(page.tab)
	_rebuild_topbar()
	page.on_shown()
	_refresh_listening()


## Shows the reader for the book and waits until its chapter has loaded (or failed),
## so a caller can start reading aloud as soon as this returns.
func open_reader(book_id: String, chapter := -1) -> void:
	var reader: ReaderPage = pages.reader
	reader.tab = 0
	if current != reader:
		navigate("reader")
	await reader.open_book(book_id, chapter)
	if current == reader:
		_rebuild_topbar()


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


func _listen_button_wanted() -> bool:
	return _listening_page() != "" and not _listening_visible()


func _refresh_listening() -> void:
	if _nav == null:
		return
	_nav.clear_listening()
	var show := _listen_button_wanted()
	if is_instance_valid(_top_listen) and _top_listen.visible != show:
		_top_listen.visible = show
		if not rail_active() and not _fit.top_holes().is_empty():
			_rebuild_topbar.call_deferred()  # the row's fit around the hole changed
	if not show:
		return
	var title := _listening_title()
	var tip := "%s: %s — click to jump there" % ["Paused" if Speech.paused else "Listening", title]
	if is_instance_valid(_top_listen):
		_top_listen.tooltip_text = tip
	_nav.add_listening_card(title, tip)


func _on_resize() -> void:
	_fit.update_safe_area()
	var viewport := get_viewport_rect().size
	var r := viewport.y < RAIL_MAX_HEIGHT and viewport.x > viewport.y
	var c := r or viewport.x < COMPACT_WIDTH
	if _drawer.visible:
		_sidebar.size.x = _drawer_width()
	if c == compact and r == rail and _laid_out:
		return
	_laid_out = true
	compact = c
	rail = r
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
	var bar_style := _topbar.get_theme_stylebox("panel") as StyleBoxFlat
	bar_style.content_margin_left = 8 if compact else 28
	# Phones keep both edges tight, so the tab strip's arrows sit near the screen edge.
	bar_style.content_margin_right = 8 if compact else 20
	for p in pages.values():
		p.set_compact(compact)
	_rebuild_topbar()


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
	var use_rail := rail_active()
	_topbar.visible = not use_rail
	_rail_scroll.visible = use_rail
	_rail_sep.visible = use_rail
	if use_rail:
		_tab_strip = null
		_top_listen = null
		UI.clear(_top_rows)
		_nav.rebuild_rail()
		_refresh_listening()
		return
	UI.clear(_rail_box)
	# A page may reuse a control in the new bar (the library's filter box), so
	# give focus back to it afterwards: typing there mustn't stop mid-word.
	var focus := get_viewport().gui_get_focus_owner()
	if focus and not _top_rows.is_ancestor_of(focus):
		focus = null
	if focus:
		_refocus.call_deferred(focus)
	# The bar is rebuilt whenever the page's header changes (a filter, a tab),
	# so carry the tabs' sideways scroll over or the row would jump back.
	var tab_scroll := 0.0
	if is_instance_valid(_tab_strip) and _tab_strip_page == current:
		tab_scroll = _tab_strip.scroll_offset
	_tab_strip = null
	UI.clear(_top_rows)
	_top_listen = null
	var row := UI.hbox(14)
	row.custom_minimum_size.y = TopBarFit.TOP_ROW_HEIGHT
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

	var names := current.tabs()
	if names.size() > 0:
		_tab_strip = TabStrip.new(names, current.tab, func(i: int): current.select_tab(i); _refresh_listening(), compact)
		_tab_strip.scroll_offset = tab_scroll
		_tab_strip_page = current

	var actions := UI.hbox(6)
	actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if compact:
		# The sidebar's "now listening" card is hidden in the drawer, so offer
		# a jump button here instead.
		_top_listen = UI.icon_button("headphones", "", show_listening)
		_top_listen.icon = Icons.get_icon("headphones", Color.WHITE, 20)
		for c in ["icon_normal_color", "icon_hover_color", "icon_pressed_color"]:
			_top_listen.add_theme_color_override(c, UiTheme.ACCENT)
		# Set now, not in _refresh_listening: a hidden button must not count
		# when the row is fitted around the camera hole.
		_top_listen.visible = _listen_button_wanted()
		actions.add_child(_top_listen)
	current.build_actions(actions)

	if compact:
		if not title_fills:
			row.add_child(UI.spacer())
		# Each button goes in the row on its own, so they can sit on either side
		# of the camera hole instead of all having to fit on one side.
		for c: Control in actions.get_children():
			actions.remove_child(c)
			c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(c)
		actions.free()
		_top_rows.add_child(row)
		if _tab_strip:
			_top_rows.add_child(_tab_strip)
		# A lone menu button up there looks lost, so the title joins it. With a
		# back button (e.g. an open book) the buttons fill the strip well enough.
		_fit.place_top_row(row, title_ctl, not current.has_back())
	else:
		if _tab_strip:
			var sep := ColorRect.new()
			sep.color = UiTheme.BORDER
			sep.custom_minimum_size = Vector2(1, 22)
			sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(sep)
			# The strip fills the gap up to the actions and scrolls when the
			# window is too narrow for every tab, instead of pushing them off.
			_tab_strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(_tab_strip)
		else:
			row.add_child(UI.spacer())
		row.add_child(actions)
		_top_rows.add_child(row)
		_fit.place_top_row(row, title_ctl)
		_fit_search_box()
		_fit_search_box.call_deferred()
	_refresh_listening()


func rail_active() -> bool:
	return rail and current != null and current.supports_rail()


func rail_button(icon: String, tip: String, callback: Callable) -> Button:
	var b := UI.icon_button(icon, tip, callback)
	b.custom_minimum_size = Vector2(40, 40)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return b


## Frees room for overflowing tabs by shrinking the page's search field to an
## icon. It only grows back once the whole field fits, so it can't flip-flop.
func _fit_search_box() -> void:
	if _tab_strip == null:
		return
	var search: SearchBox = null
	for c in _top_rows.find_children("*", "SearchBox", true, false):
		search = c
		break
	if search == null:
		return
	if not _tab_strip.resized.is_connected(_fit_search_box):
		_tab_strip.resized.connect(_fit_search_box)
	if not search.refit_wanted.is_connected(_fit_search_box):
		search.refit_wanted.connect(_fit_search_box)
	if not search.collapsed and search.can_collapse() and _tab_strip.overflow() > 0.5:
		search.collapsed = true
	elif search.collapsed and -_tab_strip.overflow() >= search.grow_cost():
		search.collapsed = false


func _refocus(c) -> void:  # untyped: it may be freed by now
	if is_instance_valid(c) and c.is_inside_tree() and c.is_visible_in_tree():
		c.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _drawer.visible:
		close_drawer()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") and current and current.has_back():
		current.go_back()
		get_viewport().set_input_as_handled()


# A drawn frame proves the GL surface is back, so icons made while the app was
# away can be uploaded again. Skipped when a pause came after this resume.
func _reupload_icons() -> void:
	_icon_generation += 1
	var gen := _icon_generation
	await RenderingServer.frame_post_draw
	if gen != _icon_generation:
		return
	Icons.app_resumed()


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
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		Icons.app_paused()
		_icon_generation += 1
		_hide_stray_keyboard()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_fit.update_safe_area()
		_reupload_icons()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		var t := Time.get_ticks_msec()
		Speech.stop()
		AppLog.info("close", "speech stopped in %d ms" % AppLog.since(t))
		Plugins.shutdown_all()
