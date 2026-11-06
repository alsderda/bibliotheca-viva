class_name WebPage
extends Page
## Built-in browser (system WebView via godot-wry). You browse normally; the
## app reads the page you have open, can read it aloud while highlighting the
## paragraph on the page, follow the site's "Next chapter" link when a chapter
## ends, and save chapters you open into the library.
##
## Nothing is downloaded in the background: every chapter is a page you (or
## auto-next, at listening speed) actually opened.

var web: Control                  # WebView
var info := {}                    # last page analysis from the injected script
var book_id := ""                 # library book matching the current page, if any

var _address: LineEdit
var _status_icon: TextureRect
var _status: Label
var _listen_btn: Button
var _save_btn: Button
var _add_btn: Button
var _search_btn: Button
var _auto_next: CheckButton
var _save_toggle: CheckButton
var _player: PanelContainer
var _play_btn: Button
var _player_label: Label
var _rate_btn: Button
var _pending_listen := false
var _back_stack: Array = []
var _sites_pop: Popover


static func available() -> bool:
	return ClassDB.class_exists("WebView")


func _ready() -> void:
	var col := UI.vbox(0)
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(col)
	col.add_child(_build_toolbar())
	if not available():
		var l := UI.label("The built-in browser isn't available on this platform yet. Desktop builds use the system web view (WebKit, WebView2 or WebKitGTK).", "Muted", true)
		col.add_child(UI.margin(l, 32, 32, 32, 0))
		return
	web = ClassDB.instantiate("WebView")
	web.set("full_window_size", false)  # default true covers the whole app window
	web.set("data_directory", ProjectSettings.globalize_path(Settings.data_dir() + "/web"))
	web.set("devtools", OS.is_debug_build())
	var start: String = Settings.get_value("web_last_url")
	web.set("url", start if start != "" else Settings.get_value("web_home"))
	web.size_flags_vertical = Control.SIZE_EXPAND_FILL
	web.connect("ipc_message", _on_ipc)
	web.connect("page_load_started", _on_load_started)
	web.connect("page_load_finished", _on_load_finished)
	col.add_child(web)
	col.add_child(_build_player())

	Speech.paragraph_started.connect(_on_paragraph)
	Speech.state_changed.connect(func(_p): _update_player())
	Speech.reached_end.connect(_on_speech_end)
	Speech.sleep_triggered.connect(func(): if Speech.source_owner == "web": _eval("window.__sr && __sr.clear()"))
	Settings.changed.connect(func(k): if k == "tts_rate": _update_player())
	SavedSearches.changed.connect(func(): if info.has("listing"): _refresh_toolbar())
	Plugins.changed.connect(func(): header_changed.emit())  # the sites menu in the title
	Settings.changed.connect(func(k): if k == "site_rules": _eval(WebExtract.script()))  # read the page again with the new rules


func page_title() -> String:
	return "Web"


func build_actions(bar: HBoxContainer) -> void:
	bar.add_child(UI.icon_button("arrow_left", "Back", func(): _eval("history.back()")))
	bar.add_child(UI.icon_button("arrow_right" if Icons.PATHS.has("arrow_right") else "chev_right", "Forward", func(): _eval("history.forward()")))
	bar.add_child(UI.icon_button("refresh", "Reload", func(): if web: web.call("reload")))
	_address = LineEdit.new()
	_address.custom_minimum_size = Vector2(160 if compact else 420, 38)
	_address.placeholder_text = "Search or enter a web address"
	_address.text = info.get("url", Settings.get_value("web_last_url"))
	_address.select_all_on_focus = true
	_address.text_submitted.connect(func(t): open_url(t))
	bar.add_child(_address)
	bar.add_child(UI.icon_button("globe", "Site rule: tell the app where the text and links are on this site", _edit_site_rule))


## The title doubles as the menu of serial sites (from plugins with a home page).
func title_control() -> Control:
	var homes := Plugins.with_home()
	if not available() or homes.is_empty():
		return null
	var b := UI.button(page_title(), "", "GhostButton")
	b.icon = Icons.get_icon("chev_down", UiTheme.MUTED, 18)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT  # the side the menu opens on
	b.tooltip_text = "Serial sites"
	b.add_theme_font_override("font", UiTheme.sans_semibold)
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(func(): _open_sites_menu(b, homes))
	return b


## Opens the sites menu to the left of the title, over the sidebar and clear of
## the page: the native web view draws over every Godot control, so a menu over
## it would be cut off. Only where there's no room (compact layout, no sidebar)
## does the page hide while the menu is open.
func _open_sites_menu(anchor: Control, homes: Array) -> void:
	var list := UI.vbox(2)
	var pop := Popover.show_for(anchor, list, false, true)
	_sites_pop = pop
	pop.card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SURFACE_2, 10, UiTheme.BORDER, 1, Vector4(6, 6, 6, 6)))
	for p in homes:
		var b := UI.button(p.name, "", "GhostButton", func():
			pop.close()
			open_url(p.home_url()))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		list.add_child(b)
	pop.tree_exiting.connect(func(): _cover_web(false))
	# Runs after the popover has placed itself: keep it clear of the page.
	(func():
		if not is_instance_valid(pop) or web == null:
			return
		var page := web.get_global_rect()
		var x := page.position.x - pop.card.size.x  # the point sits above the page, so it may stick out
		if x >= 8:
			pop.card.position.x = minf(pop.card.position.x, x)
		if pop.card.get_global_rect().intersects(page):
			_cover_web(true)).call_deferred()


func on_shown() -> void:
	if web:
		web.call("update_visibility")


func on_hidden() -> void:
	if web:
		web.call_deferred("update_visibility")


func open_url(text: String) -> void:
	if web == null:
		return
	var url := text.strip_edges()
	if url == "":
		return
	if not url.contains("://"):
		url = ("https://" + url) if (url.contains(".") and not url.contains(" ")) else "https://duckduckgo.com/?q=" + url.uri_encode()
	web.call("load_url", url)


## Opens this site's rule, or a new one for it.
func _edit_site_rule() -> void:
	var host := SiteRules.host_of(info.get("url", Settings.get_value("web_last_url")))
	var r := SiteRules.for_host(host)
	var ed := SiteRuleEditor.open(main, r if not r.is_empty() else {"host": host})
	_cover_web(true)
	ed.closed.connect(func(): _cover_web(false))


## Hides the web view while something has to show over it: the native web
## view draws over every Godot control.
func _cover_web(covered: bool) -> void:
	if is_instance_valid(web):
		web.visible = not covered
		web.call("update_visibility")


# --- toolbar (what the app found on this page) -------------------------------

func _build_toolbar() -> Control:
	var bar := PanelContainer.new()
	var st := UiTheme.box(UiTheme.SURFACE, 0, UiTheme.BORDER, 0, Vector4(20, 8, 16, 8))
	st.border_width_bottom = 1
	st.border_color = UiTheme.BORDER
	bar.add_theme_stylebox_override("panel", st)
	var row := UI.hbox(10)
	_status_icon = UI.icon("globe", UiTheme.MUTED, 18)
	row.add_child(_status_icon)
	_status = UI.label("Open a chapter page to listen to it.", "Small")
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status.custom_minimum_size.x = 60
	row.add_child(_status)
	_auto_next = _toggle("Auto-next", "web_auto_next", "When a chapter ends, open the next chapter and keep listening.")
	_save_toggle = _toggle("Save as I go", "web_save_as_you_go", "Store chapters you open here in your library.")
	row.add_child(_auto_next)
	row.add_child(_save_toggle)
	_add_btn = UI.button("Add to library", "plus", "", _add_to_library)
	_save_btn = UI.button("Save chapter", "download", "", func(): _save_current(true))
	_listen_btn = UI.button("Listen", "headphones", "PrimaryButton", toggle_listen)
	_search_btn = UI.button("Save search", "bell", "", _save_search)
	_search_btn.tooltip_text = "Check this list now and then, and show works that are new on it in Updates."
	TipAbove.apply(_search_btn)
	_search_btn.hide()
	row.add_child(_search_btn)
	for b in [_add_btn, _save_btn, _listen_btn]:
		b.disabled = true
		row.add_child(b)
	bar.add_child(row)
	return bar


func _toggle(text: String, key: String, tip: String) -> CheckButton:
	var c := CheckButton.new()
	TipAbove.apply(c)
	c.text = text
	c.tooltip_text = tip
	c.focus_mode = Control.FOCUS_NONE
	c.button_pressed = bool(Settings.get_value(key))
	c.add_theme_font_size_override("font_size", 13)
	c.toggled.connect(func(v): Settings.set_value(key, v))
	return c


func set_compact(v: bool) -> void:
	super(v)
	if _auto_next:
		_auto_next.text = "" if v else "Auto-next"
		_save_toggle.text = "" if v else "Save as I go"
		_add_btn.text = "" if v else "Add to library"
		_save_btn.text = "" if v else "Save chapter"
		_refresh_toolbar()


func _refresh_toolbar() -> void:
	var has_text: bool = info.get("paragraphs", []).size() > 0
	var is_chapter: bool = has_text and info.get("isChapter", false)
	var has_fiction: bool = _known_site() and info.has("fiction")
	_listen_btn.disabled = not has_text
	_save_btn.disabled = not is_chapter
	_add_btn.disabled = not (has_fiction or is_chapter)
	var existing := Library.get_book(book_id)
	_add_btn.text = ("In library" if not existing.is_empty() else "Add to library") if not compact else ""
	var listing: bool = info.has("listing") and Plugins.listing_plugin(info.get("url", "")) != null
	var saved := listing and not SavedSearches.find_by_url(info.url).is_empty()
	_search_btn.visible = listing
	_search_btn.text = "" if compact else ("Search saved" if saved else "Save search")
	_search_btn.icon = Icons.get_icon("check" if saved else "bell", UiTheme.TEXT, 18)
	if info.get("challenge", false):
		_set_status("shield", UiTheme.WARN, "The site is checking your browser. Complete the check and the page will load." + (" Listening continues after." if _pending_listen else ""))
	elif is_chapter:
		var where := ""
		if not existing.is_empty():
			var idx := Library.chapter_index(existing, _chapter_url())
			where = "  ·  saved" if idx >= 0 and Library.has_chapter(book_id, idx) and not Library.load_chapter(book_id, idx).get("excerpt", false) else ""
		_set_status("book", UiTheme.GOOD, "%s — %s  ·  %d paragraphs%s" % [info.get("fictionTitle", ""), info.get("chapterTitle", ""), info.paragraphs.size(), where])
	elif listing:
		var news: int = info.get("new_works", 0)
		_set_status("search", UiTheme.ACCENT, "%s · %d works on this page%s" % [info.listing.name, info.listing.count,
			("  ·  %d new since last time" % news) if news > 0 else ("  ·  saved search" if saved else "")])
	elif has_fiction:
		_set_status("library", UiTheme.ACCENT, "%s · %d chapters on this page" % [info.fiction.title, info.fiction.chapters.size()])
	elif has_text:
		_set_status("book", UiTheme.MUTED, "%d paragraphs of text on this page%s" % [info.paragraphs.size(), "  ·  site rule" if info.get("siteRule", "") != "" else ""])
	else:
		_set_status("globe", UiTheme.MUTED, "Open a chapter page to listen to it.")


func _set_status(icon: String, color: Color, text: String) -> void:
	_status_icon.texture = Icons.get_icon(icon if Icons.PATHS.has(icon) else "info", color, 18)
	_status.text = text
	_status.add_theme_color_override("font_color", color if color != UiTheme.MUTED else UiTheme.MUTED)


# --- page events -------------------------------------------------------------

func _on_load_started(url: String) -> void:
	info = {"url": url}
	if is_instance_valid(_sites_pop):
		_sites_pop.close()  # clicks on the page never reach it
	if _address and not _address.has_focus():
		_address.text = url
	_refresh_toolbar()
	_set_status("refresh", UiTheme.MUTED, "Loading…")


func _on_load_finished(url: String) -> void:
	Settings.set_value("web_last_url", url)
	if _address and not _address.has_focus():
		_address.text = url
	await get_tree().create_timer(0.4).timeout  # let late scripts settle
	_eval(WebExtract.script())


func _on_ipc(message: String) -> void:
	var data: Variant = JSON.parse_string(message)
	if not (data is Dictionary):
		return
	match data.get("type", ""):
		"page": _on_page(data)
		"jump":
			if not info.get("paragraphs", []).is_empty():
				start_listening(int(data.i))


func _on_page(data: Dictionary) -> void:
	info = data
	var fiction_url: String = data.get("fictionUrl", "")
	book_id = Library.find_by_url(fiction_url).get("id", "") if fiction_url != "" else ""
	if _known_site() and data.has("fiction") and book_id != "":
		_sync_fiction(Library.get_book(book_id), data.fiction)
	if data.get("isChapter", false) and data.paragraphs.size() > 0 and Settings.get_value("web_save_as_you_go"):
		_save_current(false)
	_mark_new_works()
	_refresh_toolbar()
	if _pending_listen and not data.get("challenge", false) and data.paragraphs.size() > 0:
		_pending_listen = false
		start_listening(0)


# --- listening ---------------------------------------------------------------

func toggle_listen() -> void:
	if Speech.playing and Speech.source_owner == "web":
		stop_listening()
	else:
		start_listening(int(info.get("firstVisible", 0)))


func start_listening(from := 0) -> void:
	var paras: Array = info.get("paragraphs", [])
	if paras.is_empty():
		return
	var items := paras.map(func(p): return {"text": TextRules.apply_tts(str(p.t), book_id), "kind": "heading" if p.k == "h" else "p"})
	Speech.play(items, clampi(from, 0, items.size() - 1), "web")
	_update_player()


func stop_listening() -> void:
	_pending_listen = false
	Speech.stop()
	_eval("window.__sr && __sr.clear()")
	_update_player()


func _on_paragraph(i: int) -> void:
	if Speech.source_owner != "web":
		return
	_eval("window.__sr && __sr.highlight(%d, %s)" % [i, "true" if Settings.get_value("tts_follow") else "false"])
	_update_player()


func _on_speech_end() -> void:
	if Speech.source_owner != "web":
		return
	_eval("window.__sr && __sr.clear()")
	if Speech.stops_at_chapter_end():
		Speech.set_sleep(0)
		_set_status("moon", UiTheme.ACCENT, "Sleep timer: stopped at the end of the chapter.")
		return
	var next: String = info.get("next", "")
	if next == "":
		next = _next_in_library()
	if Settings.get_value("web_auto_next") and next != "":
		_pending_listen = true
		_set_status("chev_right", UiTheme.ACCENT, "Chapter finished. Opening the next one…")
		await get_tree().create_timer(int(Settings.get_value("tts_pause_chapter")) / 1000.0).timeout
		if _pending_listen:
			_eval("window.__sr ? __sr.go(%s) : (location.href = %s)" % [JSON.stringify(next), JSON.stringify(next)])
	_update_player()


func _build_player() -> Control:
	_player = PanelContainer.new()
	var st := UiTheme.box(UiTheme.SURFACE, 0, UiTheme.BORDER, 0, Vector4(16, 8, 16, 8))
	st.border_width_top = 1
	st.border_color = UiTheme.BORDER
	_player.add_theme_stylebox_override("panel", st)
	var row := UI.hbox(8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(UI.icon_button("skip_back", "Back a sentence / paragraph", func(): Speech.skip_sentence(-1)))
	_play_btn = Button.new()
	_play_btn.focus_mode = Control.FOCUS_NONE
	_play_btn.custom_minimum_size = Vector2(42, 42)
	_play_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_play_btn.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.ACCENT, 21))
	_play_btn.add_theme_stylebox_override("hover", UiTheme.box(UiTheme.ACCENT.lightened(0.1), 21))
	_play_btn.add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.ACCENT.darkened(0.1), 21))
	_play_btn.pressed.connect(Speech.toggle)
	row.add_child(_play_btn)
	row.add_child(UI.icon_button("skip_fwd", "Forward a sentence / paragraph", func(): Speech.skip_sentence(1)))
	_player_label = UI.label("", "Small")
	_player_label.custom_minimum_size.x = 260
	row.add_child(UI.margin(_player_label, 8, 0, 8, 0))
	_rate_btn = UI.button("1x", "", "ChipButton", func():
		var r := float(Settings.get_value("tts_rate"))
		var rates := [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
		Settings.set_value("tts_rate", rates[(rates.find(r) + 1) % rates.size()])
		Speech.skip(0))
	_rate_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_rate_btn)
	row.add_child(UI.icon_button("moon", "Sleep timer", func(): Speech.cycle_sleep(); _update_player()))
	row.add_child(UI.icon_button("settings", "Voice settings", func(): main.pages.settings.tab = 1; main.navigate("settings")))
	row.add_child(UI.icon_button("x", "Stop", stop_listening))
	_player.add_child(row)
	_player.hide()
	return _player


func _update_player() -> void:
	if _player == null:
		return
	var mine := Speech.playing and Speech.source_owner == "web"
	_player.visible = mine or _pending_listen
	_play_btn.icon = Icons.get_icon("play" if Speech.paused or not mine else "pause", Color("#06121f"), 22)
	var n: int = info.get("paragraphs", []).size()
	var sleep := "" if Speech.sleep_minutes == 0 else "  ·  sleep " + Speech.sleep_label()
	_player_label.text = ("%s  ·  paragraph %d of %d%s" % [Speech.voice_name(), Speech.current + 1, max(n, 1), sleep]) if mine else "Waiting for the next chapter…"
	_rate_btn.text = "%sx" % str(float(Settings.get_value("tts_rate"))).trim_suffix(".0")
	_listen_btn.text = ("Stop" if mine else "Listen") if not compact else ""
	_listen_btn.icon = Icons.get_icon("stop" if mine else "headphones", UiTheme.TEXT if mine else Color("#06121f"), 18)
	_listen_btn.theme_type_variation = "" if mine else "PrimaryButton"


# --- library -----------------------------------------------------------------

func _ensure_book() -> Dictionary:
	var existing := Library.get_book(book_id)
	if not existing.is_empty():
		return existing
	var url: String = info.get("fictionUrl", "")
	if url == "":
		url = info.url
	var f: Dictionary = info.get("fiction", {})
	var book := Library.add_book({
		"title": f.get("title", info.get("fictionTitle", "Web page")), "author": f.get("author", ""),
		"kind": "web", "source": info.site if _known_site() else "web", "url": url,
		"cover_url": f.get("cover_url", ""), "synopsis": f.get("synopsis", ""), "tags": f.get("tags", []),
		"extra": f.get("extra", {}), "total_words": int(f.get("words", 0)), "chapters": f.get("chapters", []).map(func(c): return {"title": c.title, "url": c.url, "date": c.get("date", 0)}),
		"last_checked": Time.get_unix_time_from_system(),
	})
	book_id = book.id
	if book.cover_url != "":
		Sources.fetch_cover(book)
	return book


## A fiction page lists every chapter; use it to complete a book that only had RSS chapters.
func _sync_fiction(book: Dictionary, fiction: Dictionary) -> void:
	var words := int(fiction.get("words", 0))
	if words > 0 and words != int(book.get("total_words", 0)):
		Library.update_book(book.id, {"total_words": words})
	var chapters: Array = fiction.get("chapters", [])
	if chapters.size() <= book.chapters.size() and not book.get("rss_only", false):
		return
	Library.replace_chapters(book.id, chapters.map(func(c): return {"title": c.title, "url": c.url, "date": c.get("date", 0)}))
	var fields := {"last_checked": Time.get_unix_time_from_system()}
	if book.author == "" and fiction.get("author", "") != "":
		fields.author = fiction.author
	if book.synopsis == "" and fiction.get("synopsis", "") != "":
		fields.synopsis = fiction.synopsis
	if book.cover == "" and fiction.get("cover_url", "") != "":
		fields.cover_url = fiction.cover_url
	Library.update_book(book.id, fields)
	if fields.has("cover_url"):
		Sources.fetch_cover(Library.get_book(book.id))


func _add_to_library() -> void:
	var existed := not Library.get_book(book_id).is_empty()
	var book := _ensure_book()
	if info.has("fiction"):
		_sync_fiction(book, info.fiction)
	if info.get("isChapter", false):
		_save_current(true)
	_refresh_toolbar()
	_set_status("check", UiTheme.GOOD, ("Already in your library: %s" if existed else "Added “%s” to your library") % book.title)


## On a saved search: compare its works with the ones seen before, and highlight the new ones on the page.
func _mark_new_works() -> void:
	var works: Array = info.get("listing", {}).get("works", [])
	if works.is_empty() or SavedSearches.find_by_url(info.get("url", "")).is_empty():
		return
	var fresh := SavedSearches.page_seen(info.url, works)
	info.new_works = fresh.size()
	if not fresh.is_empty():
		var text := "%d new %s since you last looked" % [fresh.size(), "story" if fresh.size() == 1 else "stories"]
		_eval("window.__sr && __sr.markNew(%s, %s)" % [JSON.stringify(fresh), JSON.stringify(text)])


func _save_search() -> void:
	var existing := SavedSearches.find_by_url(info.url)
	if not existing.is_empty():
		main.open_saved_searches()
		return
	var s := SavedSearches.add(info.url, info.listing.name)
	if s.has("error"):
		main.toast(s.error, "error")
		return
	SavedSearches.page_seen(info.url, info.listing.get("works", []))  # what's on it now isn't new
	main.toast("Saved “%s”. Open it from Updates → Saved searches; works that are new since last time are highlighted." % s.name, "ok")
	_refresh_toolbar()


func _save_current(announce: bool) -> void:
	if not info.get("isChapter", false) or info.get("paragraphs", []).is_empty():
		return
	if not announce and Library.get_book(book_id).is_empty() and not _known_site():
		return  # only auto-save generic sites once they're in the library
	var book := _ensure_book()
	var idx := Library.chapter_index(book, _chapter_url())
	var title: String = info.get("chapterTitle", "Chapter")
	if idx < 0:
		book.chapters.append({"title": title, "url": _chapter_url(), "date": Time.get_unix_time_from_system()})
		idx = book.chapters.size() - 1
		Library.update_book(book.id, {"chapters": book.chapters})
	var html := "".join(info.paragraphs.map(func(p): return str(p.h)))
	var paras := HtmlText.to_paragraphs(html)
	if paras.is_empty():
		paras = PackedStringArray(info.paragraphs.map(func(p): return str(p.t)))
	Library.store_chapter(book.id, idx, title, paras)
	Library.set_progress(book.id, idx, 0)
	if announce:
		_set_status("check", UiTheme.GOOD, "Saved “%s” to %s" % [title, book.title])


# --- helpers -----------------------------------------------------------------

## A site one of the plugins recognises, as opposed to any other page.
func _known_site() -> bool:
	return Plugins.get_plugin(info.get("site", "")) != null


## The chapter's URL as the site's chapter list writes it (a work page may show its first chapter, etc.).
func _chapter_url() -> String:
	return info.get("chapterUrl", info.get("url", ""))


## Next chapter from the library's chapter list, for pages without a "Next" link.
func _next_in_library() -> String:
	var book := Library.get_book(book_id)
	if book.is_empty():
		return ""
	var idx := Library.chapter_index(book, _chapter_url())
	return book.chapters[idx + 1].url if idx >= 0 and idx + 1 < book.chapters.size() else ""


func _eval(js: String) -> void:
	if web:
		web.call("eval", js)
