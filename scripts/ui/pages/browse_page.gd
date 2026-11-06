class_name BrowsePage
extends Page
## Find web novels: search a source, paste a URL, or manage sources.

var _views: Array[Control] = []
var _query: LineEdit
var _source_pick: OptionButton
var _source_keys: Array = []
var _results: VBoxContainer
var _search_status: VBoxContainer
var _url_edit: LineEdit
var _url_status: Label
var _url_web_btn: Button
var _sources_box: VBoxContainer
var _how_box: VBoxContainer
var _busy := false


func _ready() -> void:
	_views = [_build_search(), _build_url(), _build_sources()]
	for v in _views:
		v.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(v)
	var refresh := func():
		if not is_visible_in_tree():
			return
		_fill_sources()
		_fill_how()
		if tab == 2:
			_build_sources_list()
	Plugins.changed.connect(refresh)
	Plugins.status_changed.connect(refresh)


func page_title() -> String:
	return "Browse"


func set_compact(v: bool) -> void:
	super(v)
	for view in _views:
		var m: MarginContainer = view.get_child(0)
		for side in ["left", "right"]:
			m.add_theme_constant_override("margin_" + side, 12 if v else 32)


func tabs() -> PackedStringArray:
	return ["Search", "Add by URL", "Sources"]


func on_shown() -> void:
	_fill_sources()
	_fill_how()


func _on_tab(i: int) -> void:
	for j in _views.size():
		_views[j].visible = i == j
	if i == 2:
		_build_sources_list()


# --- search ------------------------------------------------------------------

func _build_search() -> Control:
	var col := UI.vbox(18)
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 10)
	bar.add_theme_constant_override("v_separation", 10)
	_query = LineEdit.new()
	_query.theme_type_variation = "SearchField"
	_query.placeholder_text = "Search titles…"
	_query.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_query.custom_minimum_size = Vector2(220, 44)
	_query.text_submitted.connect(func(_t): search())
	var icon := UI.icon("search", UiTheme.FAINT, 18)
	icon.position = Vector2(12, 13)
	_query.add_child(icon)
	bar.add_child(_query)
	_source_pick = OptionButton.new()
	_source_pick.custom_minimum_size = Vector2(200, 44)
	_source_pick.focus_mode = Control.FOCUS_NONE
	bar.add_child(_source_pick)
	var go := UI.button("Search", "", "PrimaryButton", search)
	go.custom_minimum_size.y = 44
	bar.add_child(go)
	col.add_child(bar)
	_search_status = UI.vbox(8)
	col.add_child(_search_status)
	_results = UI.vbox(6)
	col.add_child(_results)
	_hint(_results, "compass", "Find something to read", "Pick a source and search. Sources come from your plugins (Settings → Plugins). Any other site can be read in the Web tab.")
	return UI.scroll(UI.margin(col, 32, 24, 32, 40))


func _fill_sources() -> void:
	var selected: String = _source_keys[_source_pick.selected] if _source_pick.selected >= 0 and _source_pick.selected < _source_keys.size() else ""
	var choices: Array = await Sources.search_choices()
	_source_pick.clear()
	_source_keys.clear()
	for c in choices:
		_source_pick.add_item(c.label)
		_source_pick.set_item_disabled(_source_keys.size(), c.disabled)
		_source_keys.append(c.key if not c.disabled else "")
	if choices.is_empty():
		_source_pick.add_item("No plugins installed")
		_source_pick.set_item_disabled(0, true)
		_source_keys.append("")
	var idx := _source_keys.find(selected)
	_source_pick.select(max(0, idx))


func select_source(domain: String) -> void:
	for i in _source_keys.size():
		if domain in str(_source_keys[i]):
			_source_pick.select(i)
			return


func search(text := "") -> void:
	if text != "":
		_query.text = text
	var q := _query.text.strip_edges()
	if q == "" or _busy:
		return
	_busy = true
	UI.clear(_results)
	UI.clear(_search_status)
	_search_status.add_child(UI.label("Searching…", "Muted"))
	var key: String = _source_keys[_source_pick.selected] if _source_pick.selected >= 0 and _source_pick.selected < _source_keys.size() else ""
	if key == "":
		_busy = false
		UI.clear(_search_status)
		_search_status.add_child(_banner("Install a plugin for a site to search it (Settings → Plugins). Or search the site itself in the Web tab."))
		return
	var r: Dictionary = await Sources.search(q, key)
	_busy = false
	UI.clear(_search_status)
	if r.error != "":
		_search_status.add_child(_banner(r.error, r.get("web_url", "")))
	if r.results.is_empty():
		if r.error == "":
			_hint(_results, "search", "No results", "Try a different title or source.")
		return
	_search_status.add_child(UI.label("%d results" % r.results.size(), "Muted"))
	for item in r.results:
		_results.add_child(_result_row(item))


func _result_row(item: Dictionary) -> Control:
	var row := UI.hbox(14)
	var cover := CoverView.new()
	cover.custom_minimum_size = Vector2(44, 66)
	cover.radius = 5
	cover.set_book({"title": item.title})
	row.add_child(cover)
	if item.get("cover_url", "") != "":
		_load_thumb(cover, item)
	var info := UI.vbox(3)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var t := UI.label(item.title, "H3")
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.custom_minimum_size.x = 100
	info.add_child(t)
	var meta := UI.hbox(8)
	meta.add_child(UI.chip(item.url.get_slice("/", 2).trim_prefix("www.")))
	if item.get("info", "") != "":
		var il := UI.label(str(item.info), "Small")
		il.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		il.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		il.custom_minimum_size.x = 20
		meta.add_child(il)
	info.add_child(meta)
	row.add_child(info)
	var existing := Library.find_by_url(item.url)
	var btn: Button
	if existing.is_empty():
		btn = UI.button("" if compact else "Add", "plus", "", Callable())
		btn.pressed.connect(func(): _add(item.url, btn))
	else:
		btn = UI.button("" if compact else "Open", "book", "", func(): main.open_reader(existing.id))
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(btn)
	var p := UI.panel("Row", row)
	p.mouse_filter = Control.MOUSE_FILTER_PASS
	p.mouse_entered.connect(func(): p.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SURFACE, 10, Color.TRANSPARENT, 0, Vector4(12, 10, 12, 10))))
	p.mouse_exited.connect(func(): p.remove_theme_stylebox_override("panel"))
	return p


func _load_thumb(cover: CoverView, item: Dictionary) -> void:
	var path := "user://thumb_%d.png" % abs((item.url + "\n" + item.cover_url).hash())
	if not FileAccess.file_exists(path):
		# Results replaced by a new search are freed; their covers aren't downloaded.
		var img := await Net.get_image(item.cover_url, func(): return is_instance_valid(cover))
		if img == null or not is_instance_valid(cover):
			return
		img.save_png(path)
	cover.set_book({"title": item.title, "cover": path})


func _add(url: String, btn: Button = null) -> void:
	if btn:
		btn.disabled = true
		btn.text = "Adding…"
	var book := await Sources.add_from_url(url)
	if book.has("error"):
		main.toast(book.error, "error")
		if btn:
			btn.disabled = false
			btn.text = "Add"
			if book.get("web_url", "") != "":  # blocked: offer the Web tab instead
				btn.text = "" if compact else "Web tab"
				btn.icon = Icons.get_icon("globe", UiTheme.TEXT, 18)
				for c in btn.pressed.get_connections():
					btn.pressed.disconnect(c.callable)
				btn.pressed.connect(func(): main.open_web(book.web_url))
		return
	main.toast("Added “%s” · %d chapters" % [book.title, book.chapters.size()], "ok")
	if btn:
		btn.disabled = false
		btn.text = "Open"
		btn.icon = Icons.get_icon("book", UiTheme.TEXT, 18)
		for c in btn.pressed.get_connections():
			btn.pressed.disconnect(c.callable)
		btn.pressed.connect(func(): main.open_reader(book.id))


# --- add by url --------------------------------------------------------------

func _build_url() -> Control:
	var col := UI.vbox(16)
	var card := UI.panel("Card")
	var inner := UI.vbox(12)
	inner.add_child(UI.label("Add a web novel by link", "H2"))
	inner.add_child(UI.label("Paste the link to a novel's main page (not a chapter). A search link on a site whose plugin can watch searches is saved as a search: new works on it show up in Updates.", "Muted", true))
	var row := UI.hbox(10)
	_url_edit = LineEdit.new()
	_url_edit.placeholder_text = "https://…"
	_url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_url_edit.custom_minimum_size.y = 44
	_url_edit.text_submitted.connect(func(_t): _add_url())
	row.add_child(_url_edit)
	var add := UI.button("Add to library", "plus", "PrimaryButton", _add_url)
	add.custom_minimum_size.y = 44
	row.add_child(add)
	inner.add_child(row)
	_url_status = UI.label("", "Small", true)
	inner.add_child(_url_status)
	_url_web_btn = _web_button("")
	_url_web_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_url_web_btn.hide()
	inner.add_child(_url_web_btn)
	card.add_child(inner)
	col.add_child(card)

	_how_box = UI.vbox(10)
	col.add_child(UI.margin(_how_box, 4, 8, 4, 0))
	_fill_how()
	return UI.scroll(UI.margin(col, 32, 24, 32, 40))


## How links are handled: one row per plugin, then everything else.
func _fill_how() -> void:
	if _how_box == null:
		return
	UI.clear(_how_box)
	_how_box.add_child(UI.label("HOW LINKS ARE HANDLED", "Overline"))
	for p in Plugins.plugins:
		_how_box.add_child(_how_row("globe", p.name, p.manifest.get("description", "")))
	_how_box.add_child(_how_row("globe", "Other sites", "Open them in the Web tab: Add to library and Save as I go work on any page. Plugins for more sites can be installed in Settings → Plugins."))


func _how_row(icon: String, title: String, text: String) -> Control:
	var row := UI.hbox(12, [UI.icon(icon, UiTheme.ACCENT, 20)])
	var v := UI.vbox(2)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UI.label(title, "H3"))
	v.add_child(UI.label(text, "Muted", true))
	row.add_child(v)
	return row


func _add_url() -> void:
	var url := _url_edit.text.strip_edges()
	if url == "":
		return
	_url_status.text = "Fetching novel info…"
	_url_status.add_theme_color_override("font_color", UiTheme.MUTED)
	_url_web_btn.hide()
	if Plugins.listing_plugin(url) != null:  # a search: save it instead
		var saved := SavedSearches.add(url)
		_url_status.text = saved.get("error", "Saved the search “%s”. It's in Updates → Saved searches." % saved.get("name", ""))
		_url_status.add_theme_color_override("font_color", UiTheme.BAD if saved.has("error") else UiTheme.GOOD)
		if not saved.has("error"):
			_url_edit.text = ""
		return
	var book := await Sources.add_from_url(url)
	if book.has("error"):
		_url_status.text = book.error
		_url_status.add_theme_color_override("font_color", UiTheme.BAD)
		var web_url: String = book.get("web_url", "")
		if web_url != "":
			for c in _url_web_btn.pressed.get_connections():
				_url_web_btn.pressed.disconnect(c.callable)
			_url_web_btn.pressed.connect(func(): main.open_web(web_url))
			_url_web_btn.show()
		return
	_url_status.text = "Added “%s” with %d chapters%s." % [book.title, book.chapters.size(), " (RSS preview mode)" if book.get("rss_only") else ""]
	_url_status.add_theme_color_override("font_color", UiTheme.GOOD)
	_url_edit.text = ""


# --- sources -----------------------------------------------------------------

func _build_sources() -> Control:
	_sources_box = UI.vbox(16)
	return UI.scroll(UI.margin(_sources_box, 32, 24, 32, 40))


func _build_sources_list() -> void:
	UI.clear(_sources_box)
	var head := UI.hbox(10)
	var intro := UI.label("Each site the app can search and download from is a plugin. Install, update and switch them off in Settings → Plugins.", "Muted", true)
	intro.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(intro)
	head.add_child(UI.button("Manage plugins", "settings", "", func(): main.open_plugin_settings()))
	_sources_box.add_child(head)
	if Plugins.entries.is_empty():
		_hint(_sources_box, "globe", "No plugins yet", "Install plugins for the sites you read in Settings → Plugins. Without them, the Web tab still lets you read, listen to and save any site.")
		return
	for e in Plugins.entries:
		var p: SourcePlugin = e.plugin
		var dot := UiTheme.GOOD
		var state := "Ready"
		if not e.enabled:
			dot = UiTheme.FAINT
			state = "Off"
		elif e.error != "":
			dot = UiTheme.WARN
			state = "Can't run"
		elif p and not p.status().is_empty():
			dot = UiTheme.GOOD if p.status().get("ok", false) else UiTheme.FAINT
			state = p.status().get("text", "")
		var desc: String = e.error if e.error != "" else str(e.manifest.get("description", ""))
		var card := _source_card("globe", e.name,
			"Plugin %s%s" % [e.version, " · from the plugins folder" if e.origin == "dev" else ""], desc, dot, state)
		if p and e.enabled:
			for c in p.card_controls():
				card.get_child(0).add_child(c)
		_sources_box.add_child(card)


func _source_card(icon: String, title: String, subtitle: String, desc: String, dot: Color, status: String) -> PanelContainer:
	var card := UI.panel("Card")
	var col := UI.vbox(10)
	var head := UI.hbox(12, [UI.icon(icon, UiTheme.ACCENT, 22)])
	var tv := UI.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.add_child(UI.label(title, "H3"))
	tv.add_child(UI.label(subtitle, "Small"))
	head.add_child(tv)
	var d := ColorRect.new()
	d.color = dot
	d.custom_minimum_size = Vector2(8, 8)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(d)
	head.add_child(UI.label(status, "Small"))
	col.add_child(head)
	col.add_child(UI.label(desc, "Muted", true))
	card.add_child(col)
	return card


func _banner(text: String, web_url := "") -> Control:
	var row := UI.hbox(10, [UI.icon("info", UiTheme.WARN, 18)])
	var l := UI.label(text, "", true)
	l.add_theme_color_override("font_color", UiTheme.WARN)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	if web_url != "":
		var b := _web_button(web_url)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(b)
	return UI.panel("Banner", row)


## Opens a page the app couldn't fetch itself in the Web tab (or the system browser).
func _web_button(url: String) -> Button:
	return UI.button("Open in Web tab" if WebPage.available() else "Open in browser", "globe", "PrimaryButton", func(): main.open_web(url))


func _hint(parent: Control, icon: String, title: String, text: String) -> void:
	var col := UI.vbox(8)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	var i := UI.icon(icon, UiTheme.FAINT, 36)
	col.add_child(i)
	var t := UI.label(title, "H2")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(t)
	var l := UI.label(text, "Muted", true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(l)
	parent.add_child(UI.margin(col, 40, 60, 40, 0))
