class_name SettingsPage
extends Page
## Reading, voice (TTS), plugin, site rule and sync settings.

const PLUGINS_TAB := 3
const SITES_TAB := 4
const SYNC_TAB := 5

var _content: VBoxContainer
var _margin: MarginContainer
var _sync_status: Label
var _sync_devices: VBoxContainer
var _folder_dialog: FileDialog
var _log_dialog: FileDialog
var _repo_lists := {}   # repo link -> what it lists (cached while the app runs)


func _ready() -> void:
	_content = UI.vbox(14)
	_margin = UI.margin(_content, 32, 24, 32, 40)
	var s := UI.scroll(_margin)
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(s)
	TextRules.changed.connect(func(): if visible and tab == 2: _rebuild_keep_scroll())
	Sync.status_changed.connect(_refresh_sync_status)
	Speech.voices_changed.connect(func(): if visible and tab == 1: _rebuild_keep_scroll())
	Plugins.changed.connect(func(): if visible and tab == PLUGINS_TAB: _rebuild_keep_scroll())
	Settings.changed.connect(func(k): if k == "site_rules" and visible and tab == SITES_TAB: _rebuild_keep_scroll())


func _rebuild_keep_scroll() -> void:
	var sc: ScrollContainer = get_child(0)
	var v := sc.scroll_vertical
	_rebuild()
	await get_tree().process_frame
	sc.scroll_vertical = v


func page_title() -> String:
	return "Settings"


func tabs() -> PackedStringArray:
	return ["Reading", "Voice", "Text rules", "Plugins", "Sites", "Sync", "About"]


func on_shown() -> void:
	_rebuild()


func set_compact(v: bool) -> void:
	super(v)
	if _margin:
		for side in ["left", "right"]:
			_margin.add_theme_constant_override("margin_" + side, 12 if v else 32)
		_margin.add_theme_constant_override("margin_top", 16 if v else 24)
		if visible:
			_rebuild_keep_scroll()


func _on_tab(_i: int) -> void:
	_rebuild()
	if get_child_count() > 0:
		(get_child(0) as ScrollContainer).scroll_vertical = 0


func _rebuild() -> void:
	if _content == null:
		return
	UI.clear(_content)
	match tab:
		0: _reading()
		1: _voice()
		2: _rules()
		3: _plugins()
		4: _sites()
		5: _sync()
		6: _about()


func _section(title: String, rows: Array) -> void:
	var card := UI.panel("Card")
	var col := UI.vbox(16)
	col.add_child(UI.label(title, "H3"))
	for r in rows:
		col.add_child(r)
	card.add_child(col)
	card.custom_minimum_size.x = 0
	_content.add_child(card)


## Label (and hint) beside a control; on narrow screens the control goes
## below the label at full width, except for switches which stay on the right.
func _row(label: String, hint: String, control: Control) -> Control:
	var v := UI.vbox(2)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UI.label(label, "", compact))
	if hint != "":
		v.add_child(UI.label(hint, "Small", true))
	if compact and not control is CheckButton:
		control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var col := UI.vbox(10, [v, control])
		return col
	var row := UI.hbox(16)
	row.add_child(v)
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(control)
	return row


## Line edit that is a fixed width beside its label, or full width when compact.
func _line_edit(text: String, width := 300) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.custom_minimum_size.x = 0 if compact else width
	return e


## Row of choice chips; wraps onto more lines when compact.
func _chip_row() -> Container:
	if not compact:
		return UI.hbox(6)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	return flow


## Label + slider row bound to a setting (also used by the reader's quick panel).
static func slider_row(label: String, key: String, lo: float, hi: float, step: float, fmt: String, width := 160) -> Control:
	var row := UI.hbox(10)
	var l := UI.label(label, "Muted")
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(Settings.get_value(key))
	s.custom_minimum_size = Vector2(width, 24)
	s.focus_mode = Control.FOCUS_NONE
	var v := UI.label(fmt % s.value, "Small")
	v.custom_minimum_size.x = 58
	s.value_changed.connect(func(x): v.text = fmt % x; Settings.set_value(key, x))
	row.add_child(s)
	row.add_child(v)
	return row


static func segmented_row(key: String, options: Array) -> Control:
	var row := UI.hbox(6)
	var group := ButtonGroup.new()
	for o in options:
		var b := UI.button(o[1], "", "ChipButton")
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = Settings.get_value(key) == o[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): Settings.set_value(key, o[0]))
		row.add_child(b)
	return row


func _slider(key: String, lo: float, hi: float, step: float, fmt := "%d") -> Control:
	var box := UI.hbox(12)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(Settings.get_value(key))
	s.custom_minimum_size = Vector2(220 if not compact else 80, 24)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL if compact else Control.SIZE_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	var l := UI.label(fmt % s.value, "Muted")
	l.custom_minimum_size.x = 48
	s.value_changed.connect(func(v): l.text = fmt % v; Settings.set_value(key, v))
	box.add_child(s)
	box.add_child(l)
	return box


func _toggle(key: String) -> CheckButton:
	var c := CheckButton.new()
	c.button_pressed = bool(Settings.get_value(key))
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(func(v): Settings.set_value(key, v))
	return c


func _segmented(key: String, options: Array) -> Control:
	var row := _chip_row()
	var group := ButtonGroup.new()
	for o in options:
		var b := UI.button(o[1], "", "ChipButton")
		if compact:
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = Settings.get_value(key) == o[0]
		b.pressed.connect(func(): Settings.set_value(key, o[0]); _rebuild_keep_scroll())
		row.add_child(b)
	return row


func _reading() -> void:
	_section("Appearance", [
		_row("Reader theme", "Background and text colours while reading.", _segmented("reader_theme", [["dark", "Dark"], ["sepia", "Sepia"], ["light", "Light"]])),
		_row("Font", "Literata (serif) or Inter (sans-serif).", _segmented("reader_font", [["serif", "Literata"], ["sans", "Inter"]])),
		_row("Text size", "", _slider("font_size", 14, 34, 1, "%dpx")),
		_row("Line spacing", "", _slider("line_spacing", 0, 20, 1)),
	])
	_section("Layout", [
		_row("Alignment", "Justified spreads each line to fill the column.", _segmented("text_align", ReaderPage.ALIGN_OPTIONS)),
		_row("Paragraph spacing", "Space between paragraphs.", _slider("paragraph_gap", 0, 60, 1, "%dpx")),
		_row("Indent first line", "Indent the start of each paragraph, like a printed book.", _toggle("first_line_indent")),
		_row("Text width", "Maximum width of the text. On narrower screens the side margins decide.", _slider("column_width", 360, 1600, 20, "%dpx")),
		_row("Side margins", "Least space kept left and right of the text.", _slider("side_margin", 0, 160, 2, "%dpx")),
	])
	# live preview
	var prev := PanelContainer.new()
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	prev.add_child(rt)
	_style_preview(prev, rt)
	var restyle := func(_k): _style_preview(prev, rt)
	Settings.changed.connect(restyle)
	prev.tree_exiting.connect(func(): Settings.changed.disconnect(restyle))
	_content.add_child(UI.margin(UI.label("PREVIEW", "Overline"), 4, 8, 0, 0))
	_content.add_child(prev)


## Shows the sample paragraphs as the reader would.
func _style_preview(prev: PanelContainer, rt: RichTextLabel) -> void:
	var c := Settings.reader_colors()
	var side := float(Settings.get_value("side_margin"))
	prev.add_theme_stylebox_override("panel", UiTheme.box(c.bg, 14, UiTheme.BORDER, 1, Vector4(side, 16, side, 16) if compact else Vector4(side, 26, side, 26)))
	var serif: bool = Settings.get_value("reader_font") == "serif"
	var size := int(Settings.get_value("font_size"))
	rt.add_theme_font_override("normal_font", UiTheme.serif if serif else UiTheme.sans)
	rt.add_theme_font_override("italics_font", UiTheme.serif_italic if serif else UiTheme.sans)
	rt.add_theme_font_size_override("normal_font_size", size)
	rt.add_theme_font_size_override("italics_font_size", size)
	rt.add_theme_color_override("default_color", c.text)
	rt.add_theme_constant_override("line_separation", int(Settings.get_value("line_spacing")) + int(size * 0.2))
	rt.add_theme_constant_override("paragraph_separation", int(Settings.get_value("paragraph_gap")))
	ReaderPage.apply_alignment(rt)
	var indent := ReaderPage.indent_bbcode(size) if Settings.get_value("first_line_indent") else ""
	rt.text = indent + "It was on a dreary night of November that I beheld the accomplishment of my toils. With an anxiety that almost amounted to [i]agony[/i], I collected the instruments of life around me.\n" + indent + "It was already one in the morning; the rain pattered dismally against the panes, and my candle was nearly burnt out."


func _voice() -> void:
	if not Speech.is_supported():
		_section("Text-to-speech", [UI.label("This platform doesn't expose system voices to Godot. On Linux install speech-dispatcher; on the web use a browser with the Web Speech API.", "Muted", true)])
		return
	var pick := OptionButton.new()
	pick.custom_minimum_size.x = 260 if not compact else 0
	pick.focus_mode = Control.FOCUS_NONE
	pick.fit_to_longest_item = false
	pick.clip_text = compact
	pick.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var current := Speech.voice_id()
	var voices := Speech.voices()
	voices.sort_custom(func(a, b): return (a.language.begins_with("en") and not b.language.begins_with("en")) or (a.language.begins_with("en") == b.language.begins_with("en") and a.name < b.name))
	for i in voices.size():
		pick.add_item("%s  (%s)" % [voices[i].name, voices[i].language])
		pick.set_item_metadata(i, voices[i].id)
		if voices[i].id == current:
			pick.select(i)
	pick.item_selected.connect(func(i): Settings.set_value("tts_voice", pick.get_item_metadata(i)))
	var voice_row := _row("Voice", "%d system voices available. Install more in your OS settings." % voices.size(), pick)
	if Speech.uses_system_voice():
		voice_row = _row("Voice", "Uses the engine and voice chosen in Android's text-to-speech settings. After switching engines, restart the app.",
			UI.button("System settings", "settings", "", func(): Speech.open_system_settings()))
	var sample := _line_edit(Settings.get_value("tts_preview_text"), 260)
	sample.size_flags_horizontal = Control.SIZE_EXPAND_FILL if compact else Control.SIZE_FILL
	sample.text_changed.connect(func(t): Settings.set_value("tts_preview_text", t))
	var test := UI.button("Test", "volume", "", func(): Speech.preview(TextRules.apply_tts(sample.text)))
	var test_row := UI.hbox(8, [sample, test])
	_section("Voice", [
		voice_row,
		_row("Speed", "1.00x is the voice's normal pace.", _slider("tts_rate", 0.5, 3.0, 0.05, "%.2fx")),
		_row("Pitch", "", _slider("tts_pitch", 0.5, 1.5, 0.05, "%.2f")),
		_row("Volume", "", _slider("tts_volume", 0, 100, 1, "%d%%")),
		_row("Test sentence", "Speech rules are applied to the test too.", test_row),
	])
	_section("Pauses and pacing", [
		_row("Speak in", "Sentences gives finer pauses and skipping; paragraphs sound more fluid on some voices.", _segmented("tts_mode", [["paragraph", "Paragraphs"], ["sentence", "Sentences"]])),
		_row("Pause between sentences", "Only in Sentences mode.", _slider("tts_pause_sentence", 0, 2000, 10, "%d ms")),
		_row("Pause between paragraphs", "", _slider("tts_pause_paragraph", 0, 3000, 10, "%d ms")),
		_row("Pause after headings", "After chapter titles and section headings.", _slider("tts_pause_heading", 0, 4000, 10, "%d ms")),
		_row("Pause before next chapter", "", _slider("tts_pause_chapter", 0, 10000, 250, "%d ms")),
		_row("Split long paragraphs", "Paragraphs longer than this are read sentence by sentence, which keeps some voices from stalling.", _slider("tts_max_chars", 200, 5000, 100, "%d chars")),
	])
	var rules_n := TextRules.rules.filter(func(r): return r.enabled and r.scope != "display").size()
	var rules_btn := UI.button("Edit speech rules (%d)" % rules_n, "replace", "", func(): select_tab(2); header_changed.emit())
	_section("What gets read", [
		_row("Read chapter titles and headings", "", _toggle("tts_read_headings")),
		_row("Skip lines without words", "Scene breaks like “* * *” or “~~~”.", _toggle("tts_skip_symbols")),
		_row("Pronunciation and skipping", "Use rules to fix names or keep things like [system notices] from being read.", rules_btn),
	])
	_section("While reading aloud", [
		_row("Highlight", "How the paragraph being read is marked.", _segmented("tts_highlight", [["background", "Background"], ["underline", "Underline"], ["color", "Colour"], ["none", "None"]])),
		_row("Follow along", "Scroll the text to the paragraph being read.", _toggle("tts_follow")),
		_row("Continue to next chapter", "Keep reading aloud when a chapter ends.", _toggle("tts_auto_advance")),
		_row("Sleep timer", "Stop reading after a while. Also on the player's moon button.", _sleep_picker()),
	])


func _sleep_picker() -> Control:
	var row := _chip_row()
	var group := ButtonGroup.new()
	for m in [0, 15, 30, 60, -1]:
		var b := UI.button("Off" if m == 0 else ("Chapter end" if m == -1 else "%d min" % m), "", "ChipButton")
		if compact:
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = Speech.sleep_minutes == m
		b.pressed.connect(func(): Speech.set_sleep(m))
		row.add_child(b)
	return row


# --- text rules --------------------------------------------------------------

func _rules() -> void:
	var intro := UI.vbox(10)
	var head := UI.hbox(10)
	var title := UI.vbox(2)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_child(UI.label("Text and speech rules", "H3"))
	title.add_child(UI.label("Find-and-replace rules run on every chapter. Use them to fix how names are pronounced, keep things from being read aloud, or clean up the text. Rules run top to bottom.", "Muted", true))
	head.add_child(title)
	intro.add_child(head)
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 8)
	actions.add_child(UI.button("New rule", "plus", "PrimaryButton", func(): RuleEditor.open(main, {})))
	var examples := MenuButton.new()
	examples.text = "Add example"
	examples.icon = Icons.get_icon("sparkle", UiTheme.TEXT, 18)
	examples.flat = false
	examples.focus_mode = Control.FOCUS_NONE
	for i in TextRules.EXAMPLES.size():
		examples.get_popup().add_item(TextRules.EXAMPLES[i].name, i)
	examples.get_popup().id_pressed.connect(func(i): TextRules.add_rule(TextRules.new_rule(TextRules.EXAMPLES[i])); main.toast("Added “%s”" % TextRules.EXAMPLES[i].name, "ok"))
	actions.add_child(examples)
	actions.add_child(UI.button("Copy all", "copy", "", func(): DisplayServer.clipboard_set(TextRules.export_json()); main.toast("Rules copied to the clipboard as JSON", "ok")))
	actions.add_child(UI.button("Paste rules", "clipboard", "", func():
		var n := TextRules.import_json(DisplayServer.clipboard_get())
		main.toast("Clipboard doesn't contain rules" if n < 0 else "Imported %d rule(s)" % n, "warn" if n < 0 else "ok")))
	intro.add_child(actions)
	var card := UI.panel("Card", intro)
	_content.add_child(card)

	if TextRules.rules.is_empty():
		var empty := UI.vbox(6)
		empty.add_child(UI.label("No rules yet", "H3"))
		empty.add_child(UI.label("Tip: in the reader, select a word and right-click it to fix its pronunciation.", "Muted", true))
		_content.add_child(UI.margin(empty, 6, 10, 0, 0))
	else:
		var list := UI.vbox(4)
		for i in TextRules.rules.size():
			list.add_child(_rule_row(TextRules.rules[i], i))
		_content.add_child(UI.panel("Card", list))

	# Try all rules
	var tester := UI.vbox(10)
	tester.add_child(UI.label("Try your rules", "H3"))
	var input := TextEdit.new()
	input.text = "“Queequeg!” Ishmael shouted. [Ship's log: day 41]\n* * *\nThe whale's HP dropped — fast."
	input.custom_minimum_size.y = 76
	input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	input.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.BG, 8, UiTheme.BORDER, 1, Vector4(10, 8, 10, 8)))
	input.add_theme_stylebox_override("focus", UiTheme.box(UiTheme.BG, 8, UiTheme.ACCENT, 1, Vector4(10, 8, 10, 8)))
	input.add_theme_color_override("font_color", UiTheme.TEXT)
	tester.add_child(input)
	var shown := UI.label("", "", true)
	var spoken := UI.label("", "", true)
	shown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spoken.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var out := UI.vbox(6, [UI.hbox(10, [UI.icon("eye"), _fixed_label("Shown"), shown]), UI.hbox(10, [UI.icon("mic"), _fixed_label("Spoken"), spoken])])
	tester.add_child(UI.panel("CardFlat", out))
	var update := func():
		var lines_shown := PackedStringArray()
		var lines_spoken := PackedStringArray()
		for line in input.text.split("\n"):
			var d := HtmlText.plain(TextRules.apply_display(line.replace("[", "\u0002").replace("]", "[rb]").replace("\u0002", "[lb]")))
			var t := TextRules.apply_tts(line).strip_edges()
			lines_shown.append(d if d.strip_edges() != "" else "(hidden)")
			if t != "":
				lines_spoken.append(t)
		shown.text = "\n".join(lines_shown)
		spoken.text = " … ".join(lines_spoken) if lines_spoken.size() > 0 else "(nothing)"
	input.text_changed.connect(update)
	update.call()
	var speak := UI.button("Speak result", "volume", "", func(): Speech.preview(spoken.text.replace(" … ", ". ")))
	speak.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tester.add_child(speak)
	_content.add_child(UI.panel("Card", tester))


func _fixed_label(t: String) -> Label:
	var l := UI.label(t, "Small")
	l.custom_minimum_size.x = 52
	return l


func _rule_row(r: Dictionary, index: int) -> Control:
	var row := UI.hbox(12)
	var on := CheckButton.new()
	on.button_pressed = r.enabled
	on.focus_mode = Control.FOCUS_NONE
	on.tooltip_text = "Enabled"
	on.toggled.connect(func(v): TextRules.set_enabled(r.id, v))
	on.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(on)
	var info := UI.vbox(3)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_l := UI.label(r.name if r.name != "" else r.pattern, "H3")
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_l.custom_minimum_size.x = 80
	if not r.enabled:
		name_l.add_theme_color_override("font_color", UiTheme.FAINT)
	info.add_child(name_l)
	var detail := UI.label("%s  →  %s" % [r.pattern, _show_replacement(r.replace)], "Small")
	detail.add_theme_font_override("font", UiTheme.mono)
	detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	detail.custom_minimum_size.x = 80
	info.add_child(detail)
	var chips := _chip_row()
	var scope_color: Color = {"tts": UiTheme.ACCENT, "display": UiTheme.WARN, "both": UiTheme.GOOD}[r.scope]
	chips.add_child(UI.chip(TextRules.SCOPE_NAMES[r.scope], scope_color))
	if r.regex:
		chips.add_child(UI.chip("regex"))
	if r.ignore_case:
		chips.add_child(UI.chip("any case"))
	if r.whole_word:
		chips.add_child(UI.chip("whole word"))
	var b := Library.get_book(r.book) if r.book != "" else {}
	chips.add_child(UI.chip(b.title.left(28) if not b.is_empty() else ("All books" if r.book == "" else "Removed book")))
	if TextRules.validate(r) != "":
		chips.add_child(UI.chip("invalid pattern", UiTheme.BAD))
	info.add_child(chips)
	row.add_child(info)
	var tools := UI.hbox(2)
	tools.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var up := UI.icon_button("arrow_up", "Move up", func(): TextRules.move_rule(r.id, -1))
	up.disabled = index == 0
	tools.add_child(up)
	var down := UI.icon_button("arrow_down", "Move down", func(): TextRules.move_rule(r.id, 1))
	down.disabled = index == TextRules.rules.size() - 1
	tools.add_child(down)
	tools.add_child(UI.icon_button("pencil", "Edit", func(): RuleEditor.open(main, r)))
	tools.add_child(UI.icon_button("trash", "Delete", func(): TextRules.remove_rule(r.id)))
	if compact:
		tools.alignment = BoxContainer.ALIGNMENT_END
		info.add_child(tools)
	else:
		row.add_child(tools)
	var p := UI.panel("Row", row)
	return p


static func _show_replacement(rep: String) -> String:
	if rep == "":
		return "(remove)"
	if rep.strip_edges() == "":
		return "(space)"
	return rep


func _plugins() -> void:
	var warn := UI.hbox(10, [UI.icon("shield", UiTheme.WARN, 18)])
	var wl := UI.label("Plugins add sites to the app: searching them, adding books by link and downloading chapters. A plugin runs inside the app with the same access the app has (your library, files and the network), so only install plugins from people you trust. With Sync on, installed plugins are copied to your other devices too.", "Muted", true)
	wl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	warn.add_child(wl)
	_content.add_child(UI.panel("Banner", warn))

	if Plugins.entries.is_empty():
		_section("Installed plugins", [UI.label("None yet. Install one from a link or a plugin repository below.", "Muted", true)])
	for e in Plugins.entries:
		_plugin_card(e)

	var link := _line_edit("", 360)
	link.placeholder_text = "Link to a plugin (its plugin.json, folder or GitHub page)"
	var install := func():
		var url := link.text.strip_edges()
		if url != "":
			_confirm_install("this plugin", url, func():
				main.toast("Installing…")
				var r: Dictionary = await Plugins.install_from_url(url)
				main.toast(r.error if r.has("error") else "Installed %s %s" % [r.name, r.version], "error" if r.has("error") else "ok"))
	link.text_submitted.connect(func(_t): install.call())
	var rows: Array = [_row("From a link", "Works on every device.", UI.hbox(8, [link, UI.button("Install", "download", "PrimaryButton", install)]))]
	if OS.has_feature("pc"):
		rows.append(_row("From a folder", "A plugin folder on this computer (one with a plugin.json).", UI.button("Choose folder…", "import", "", _choose_folder)))
	_section("Install a plugin", rows)

	var repo_rows: Array = [UI.label("A plugin repository lists several plugins. Add it once to see what it has and get updates.", "Muted", true)]
	for url in Plugins.repos():
		repo_rows.append(_repo_box(url))
	var repo := _line_edit("", 360)
	repo.placeholder_text = "Link to a repository (its index.json, folder or GitHub page)"
	var add_repo := func():
		var url := repo.text.strip_edges()
		if url == "":
			return
		var r: Dictionary = await Plugins.add_repo(url)
		if r.has("error"):
			main.toast(r.error, "error")
		else:
			_repo_lists[url] = r
			_rebuild_keep_scroll()
	repo.text_submitted.connect(func(_t): add_repo.call())
	repo_rows.append(UI.hbox(8, [repo, UI.button("Add", "plus", "", add_repo)]))
	_section("Plugin repositories", repo_rows)


# --- site rules --------------------------------------------------------------

func _sites() -> void:
	_section("Downloads", [
		_row("Reuse unchanged pages", "When a page was downloaded before, ask the site whether it changed and reuse the saved copy if it didn't. Saves the site work on update checks. Turn this off if a site keeps showing an old chapter list.", _toggle("http_revalidate")),
		_row("Keep site waits after a restart", "When a site asks the app to wait before asking again, keep waiting after the app is restarted. To clear a wait, turn this off and restart the app.", _toggle("http_keep_waits")),
	])
	var intro := UI.vbox(10)
	intro.add_child(UI.label("Site rules", "H3"))
	intro.add_child(UI.label("Tell the Web tab where the chapter text, the parts to skip, the next and previous links and the chapter title are on a site, as CSS selectors. Without a rule, the app finds the text by itself. A rule wins over what a site's plugin finds. In the Web tab, the globe button next to the address makes a rule for the site you have open.", "Muted", true))
	var add := UI.button("New site rule", "plus", "PrimaryButton", func(): SiteRuleEditor.open(main, {}))
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	intro.add_child(add)
	_content.add_child(UI.panel("Card", intro))

	var rules := SiteRules.all()
	if rules.is_empty():
		_content.add_child(UI.margin(UI.label("No site rules yet.", "Muted"), 6, 10, 0, 0))
		return
	var list := UI.vbox(4)
	for r in rules:
		list.add_child(_site_row(r))
	_content.add_child(UI.panel("Card", list))


func _site_row(r: Dictionary) -> Control:
	var row := UI.hbox(12)
	var info := UI.vbox(3)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(UI.label(r.host, "H3"))
	var chips := _chip_row()
	for f in SiteRules.FIELDS:
		if r.get(f, "") != "":
			chips.add_child(UI.chip(SiteRuleEditor.LABELS[f][0]))
	info.add_child(chips)
	row.add_child(info)
	var tools := UI.hbox(2)
	tools.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tools.add_child(UI.icon_button("pencil", "Edit", func(): SiteRuleEditor.open(main, r)))
	tools.add_child(UI.icon_button("trash", "Delete", func(): SiteRules.remove(r.id)))
	row.add_child(tools)
	return UI.panel("Row", row)


func _plugin_card(e: Dictionary) -> void:
	var head := UI.hbox(10, [UI.icon("globe", UiTheme.ACCENT, 20)])
	var tv := UI.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.add_child(UI.label(e.name, "H3"))
	var where := "installed" if e.origin == "installed" else "from the plugins folder"
	tv.add_child(UI.label("Version %s · %s%s" % [e.version, where, (" · by " + str(e.manifest.author)) if e.manifest.get("author", "") != "" else ""], "Small"))
	head.add_child(tv)
	if e.origin == "installed":
		head.add_child(UI.icon_button("trash", "Remove", func(): ConfirmDialog.open(main, {
			"title": "Remove %s?" % e.name, "icon": "trash", "confirm": "Remove", "confirm_icon": "trash", "danger": true,
			"text": "Books from it stay in your library, but can't get new chapters until it's installed again.",
		}, func(): Plugins.remove(e.id))))
	var on := CheckButton.new()
	on.button_pressed = e.enabled
	on.tooltip_text = "On / off"
	on.toggled.connect(func(v): Plugins.set_enabled(e.id, v))
	head.add_child(on)
	var rows: Array = [head]
	var desc: String = str(e.manifest.get("description", ""))
	if desc != "":
		rows.append(UI.label(desc, "Muted", true))
	if e.error != "":
		var err := UI.label(e.error, "Small", true)
		err.add_theme_color_override("font_color", UiTheme.WARN)
		rows.append(err)
	var p: SourcePlugin = e.plugin
	if p:
		for r in p.settings_rows():
			var control: Control = r[2]
			if control is LineEdit and compact:
				control.custom_minimum_size.x = 0
			rows.append(_row(r[0], r[1], control))
	var card := UI.panel("Card")
	card.add_child(UI.vbox(12, rows))
	_content.add_child(card)


## A repository's plugins, with Install / Update buttons.
func _repo_box(url: String) -> Control:
	var col := UI.vbox(6)
	var head := UI.hbox(8)
	var title := UI.label(url, "", true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(UI.icon_button("refresh", "Check again", func(): _repo_lists.erase(url); _rebuild_keep_scroll()))
	head.add_child(UI.icon_button("x", "Remove this repository", func(): Plugins.remove_repo(url); _repo_lists.erase(url); _rebuild_keep_scroll()))
	col.add_child(head)
	var list := UI.vbox(6)
	col.add_child(list)
	_fill_repo(url, title, list)
	return UI.panel("Row", col)


func _fill_repo(url: String, title: Label, list: VBoxContainer) -> void:
	if not _repo_lists.has(url):
		list.add_child(UI.label("Loading…", "Small"))
		_repo_lists[url] = await Plugins.resolve(url)
		if not is_instance_valid(list):
			return
		UI.clear(list)
	var r: Dictionary = _repo_lists[url]
	if r.has("error"):
		var err := UI.label(r.error, "Small", true)
		err.add_theme_color_override("font_color", UiTheme.WARN)
		list.add_child(err)
		return
	title.text = r.get("name", url)
	title.tooltip_text = url
	for item in r.get("plugins", []):
		var row := UI.hbox(10)
		var v := UI.vbox(0)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(UI.label("%s  ·  %s" % [item.name, item.version], ""))
		if item.description != "":
			v.add_child(UI.label(item.description, "Small", true))
		row.add_child(v)
		var have := Plugins.get_entry(item.id)
		var btn: Button
		if item.error != "":
			btn = UI.button("Can't run here", "", "", Callable())
			btn.tooltip_text = item.error
			btn.disabled = true
		elif have.is_empty() or (have.origin == "installed" and Plugins.compare_versions(item.version, have.version) > 0):
			btn = UI.button("Install" if have.is_empty() else "Update", "download", "PrimaryButton" if have.is_empty() else "", Callable())
			btn.pressed.connect(func(): _confirm_install(item.name, item.manifest_url, func():
				btn.disabled = true
				var res: Dictionary = await Plugins.install_listed(item)
				main.toast(res.error if res.has("error") else "Installed %s %s" % [res.name, res.version], "error" if res.has("error") else "ok")))
		else:
			btn = UI.button("Installed", "check", "", Callable())
			btn.disabled = true
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(btn)
		list.add_child(row)


func _confirm_install(name: String, detail: String, then: Callable) -> void:
	ConfirmDialog.open(main, {
		"title": "Install %s?" % name, "detail": detail, "icon": "shield", "confirm": "Install", "confirm_icon": "download",
		"text": "Plugins run inside the app with the same access the app has. Only install plugins from people you trust.",
	}, then)


func _choose_folder() -> void:
	if _folder_dialog == null:
		_folder_dialog = FileDialog.new()
		_folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_folder_dialog.use_native_dialog = true
		_folder_dialog.dir_selected.connect(func(path): _confirm_install("this plugin", path, func():
			var r := Plugins.install_from_folder(path)
			main.toast(r.error if r.has("error") else "Installed %s %s" % [r.name, r.version], "error" if r.has("error") else "ok")))
		add_child(_folder_dialog)
	_folder_dialog.popup_centered_ratio(0.6)


## Plain http:// sends the username and password unencrypted with every request,
## so the user has to type "confirm" before such an address is saved.
func _confirm_insecure_sync(address: String, then: Callable) -> void:
	ConfirmDialog.open(main, {
		"title": "Use an unencrypted connection?", "detail": address, "icon": "shield", "danger": true,
		"text": "This address starts with http://, not https://. Your username, password and library will be sent unencrypted, so anyone on the same network (public Wi-Fi, for example) can read them. Use https:// if your server supports it.\n\nType confirm to use this address anyway.",
		"input": "", "input_hint": "confirm", "require": "confirm", "confirm": "Use http://",
	}, func(_typed): then.call())


func _sync() -> void:
	var url := _line_edit(Sync.server_url())
	url.placeholder_text = "https://example.com/dav/"
	var user := _line_edit(Sync.user_name())
	var password := _line_edit("")
	password.secret = true
	password.placeholder_text = "saved" if Sync.has_password() else ""
	var result := UI.label("", "Small", true)
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var apply := func():
		Sync.configure(url.text, user.text, password.text)
		password.text = ""
		password.placeholder_text = "saved" if Sync.has_password() else ""
		result.text = "Connecting…"
		result.add_theme_color_override("font_color", UiTheme.MUTED)
		var err: String = await Sync.test_connection()
		result.text = "Connected." if err == "" else err
		result.add_theme_color_override("font_color", UiTheme.GOOD if err == "" else UiTheme.BAD)
	var save := UI.button("Save and test", "check", "", func():
		if url.text.strip_edges().to_lower().begins_with("http://"):
			_confirm_insecure_sync(url.text.strip_edges(), apply)
		else:
			apply.call())
	save.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var on := CheckButton.new()
	on.button_pressed = Sync.is_enabled()
	on.focus_mode = Control.FOCUS_NONE
	on.toggled.connect(func(v):
		if v and not Sync.is_configured():
			on.set_pressed_no_signal(false)
			result.text = "Enter the server address first."
			result.add_theme_color_override("font_color", UiTheme.BAD)
			return
		Sync.set_enabled(v))
	var name := _line_edit(Sync.device_name())
	name.text_submitted.connect(func(t): Sync.set_device_name(t))
	name.focus_exited.connect(func(): if name.text != Sync.device_name(): Sync.set_device_name(name.text))
	_section("Sync between devices", [
		UI.label("Keeps your library, saved chapters, reading position, text rules and settings the same on all your devices, through a folder on a WebDAV server. The app creates a bibliotheca-viva folder there.", "Muted", true),
		_row("Server address", "The WebDAV address from your provider (see below).", url),
		_row("Username", "", user),
		_row("Password", "Use an app password if your provider has them. Kept in %s." % Sync.password_store_name(), password),
		UI.hbox(12, [save, result]),
		_row("Sync", "Syncs at start, a few seconds after changes, every 10 minutes, and when closing.", on),
		_row("This device", "Shown to your other devices.", name),
	])

	_sync_status = UI.label("", "")
	_sync_devices = UI.vbox(6)
	var now := UI.button("Sync now", "refresh", "", func():
		var err: String = await Sync.sync_now(true)
		main.toast("Synced" if err == "" else "Sync failed: " + err, "ok" if err == "" else "error"))
	_section("Status", [
		UI.hbox(12, [_sync_status, UI.spacer(), now]),
		UI.label("OTHER DEVICES", "Overline"),
		_sync_devices,
	])
	_refresh_sync_status()

	_section("Where to get a WebDAV folder", [
		UI.label("Koofr (10 GB free): address https://app.koofr.net/dav/Koofr/, username is your Koofr email, and the password is an app password from Preferences → Password (your normal password won't work).", "Muted", true),
		UI.label("Nextcloud: address https://<your server>/remote.php/dav/files/<your username>/ and an app password from Settings → Security.", "Muted", true),
		UI.label("Any other WebDAV server works too. Google Drive and Dropbox don't offer WebDAV.", "Muted", true),
		UI.label("Not synced: the selected voice (voices differ between devices) and plugins' own settings. When the same setting or book is changed on two devices, the most recent change wins; chapters saved on any device are kept.", "Small", true),
	])


func _refresh_sync_status() -> void:
	if not is_instance_valid(_sync_status):
		return
	var text := ""
	var color := UiTheme.MUTED
	if Sync.running:
		text = Sync.progress_text
	elif not Sync.is_configured():
		text = "Not set up"
	elif not Sync.is_enabled():
		text = "Off"
	elif Sync.last_error != "":
		text = "Last sync failed: " + Sync.last_error
		color = UiTheme.BAD
	else:
		text = "Last synced " + UI.relative_time(Sync.last_sync)
		color = UiTheme.GOOD
	_sync_status.text = text
	_sync_status.add_theme_color_override("font_color", color)
	_sync_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sync_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if is_instance_valid(_sync_devices):
		UI.clear(_sync_devices)
		if Sync.devices.is_empty():
			_sync_devices.add_child(UI.label("None yet. Set up sync with the same folder on your other devices.", "Small", true))
		for d in Sync.devices:
			var dev := UI.label(str(d.get("name", "Unknown device")), "", true)
			dev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var changed := UI.label("changed " + UI.relative_time(float(d.get("updated", 0))), "Small")
			changed.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			_sync_devices.add_child(UI.hbox(10, [UI.icon("server"), dev, changed]))


func _about() -> void:
	_section("Bibliothéca-viva %s" % ProjectSettings.get_setting("application/config/version", "?"), [
		UI.label("Build %s" % ProjectSettings.get_setting("application/config/version_code", "?"), "Small"),
		UI.label("An ebook reader with text-to-speech, library sync over WebDAV, and a plugin system for fetching books from web serial sites. Built with Godot %s." % Engine.get_version_info().string, "Muted", true),
		_row("Data folder", ProjectSettings.globalize_path(Settings.data_dir()), UI.button("Open", "external", "", func(): OS.shell_open(ProjectSettings.globalize_path(Settings.data_dir())))),
	])
	_troubleshooting()
	var rows: Array = [UI.label("Third-party software and assets the reader uses. Sites come from plugins, which carry their own licenses.", "Muted", true)]
	for c in CREDITS:
		var links := UI.hbox(8, [
			_external_link(c.license, c.license_url),
			_external_link("Website", c.url),
		])
		rows.append(_row(c.name, c.what, links))
	_section("Credits", rows)


func _troubleshooting() -> void:
	var on := CheckButton.new()
	on.button_pressed = AppLog.is_on()
	on.focus_mode = Control.FOCUS_NONE
	on.toggled.connect(func(v): Settings.set_value("logging", v); _rebuild_keep_scroll())
	var count := AppLog.files().size()
	var kept := "No logs kept." if count == 0 else "%d %s kept, %s." % [count, "log" if count == 1 else "logs", String.humanize_size(AppLog.total_bytes())]
	var actions := _chip_row()
	actions.add_child(UI.button("Export…", "download", "", _export_log))
	actions.add_child(UI.button("Copy", "copy", "", func():
		DisplayServer.clipboard_set(AppLog.export_text())
		main.toast("Logs copied to the clipboard", "ok")))
	if OS.has_feature("pc"):
		actions.add_child(UI.button("Open folder", "external", "", func(): OS.shell_open(ProjectSettings.globalize_path(AppLog.folder()))))
	actions.add_child(UI.button("Delete", "trash", "GhostButton", func():
		AppLog.clear()
		main.toast("Old logs deleted", "ok")
		_rebuild_keep_scroll()))
	for b in actions.get_children():
		(b as Button).disabled = count == 0
	_section("Troubleshooting", [
		_row("Keep a log", "Writes what the app does, with the time, to a file on this device: errors, closing, sync and downloads. Nothing is sent anywhere. Each start makes a new log, and the last %d are kept." % AppLog.KEEP_FILES, on),
		UI.label(kept + " Export or copy them to attach to a bug report.", "Small", true),
		actions,
	])


func _export_log() -> void:
	if _log_dialog == null:
		_log_dialog = FileDialog.new()
		_log_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_log_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_log_dialog.use_native_dialog = true
		_log_dialog.filters = PackedStringArray(["*.txt ; Text files"])
		_log_dialog.file_selected.connect(func(path):
			var ok := AppLog.export_to(path)
			main.toast("Logs saved to " + path.get_file() if ok else "Couldn't save the logs there", "ok" if ok else "error"))
		add_child(_log_dialog)
	_log_dialog.current_file = "bibliotheca-viva-log-%s.txt" % Time.get_date_string_from_system()
	_log_dialog.popup_centered_ratio(0.6)


## Third-party parts the reader itself uses (plugins list their own).
const CREDITS := [
	{"name": "Godot Engine", "what": "Game engine the app is built on", "url": "https://godotengine.org",
		"license": "MIT", "license_url": "https://godotengine.org/license"},
	{"name": "Godot's bundled libraries", "what": "FreeType, HarfBuzz, ICU and others shipped inside Godot", "url": "https://github.com/godotengine/godot",
		"license": "Various", "license_url": "https://github.com/godotengine/godot/blob/master/COPYRIGHT.txt"},
	{"name": "godot-wry", "what": "Built-in browser (system web view)", "url": "https://github.com/doceazedo/godot_wry",
		"license": "MIT", "license_url": "https://github.com/doceazedo/godot_wry/blob/main/LICENSE"},
	{"name": "Inter", "what": "Interface font", "url": "https://github.com/rsms/inter",
		"license": "SIL OFL 1.1", "license_url": "https://github.com/rsms/inter/blob/master/LICENSE.txt"},
	{"name": "Literata", "what": "Reading font", "url": "https://github.com/googlefonts/literata",
		"license": "SIL OFL 1.1", "license_url": "https://github.com/googlefonts/literata/blob/main/OFL.txt"},
	{"name": "Lucide", "what": "Style the icons are drawn in", "url": "https://lucide.dev",
		"license": "ISC", "license_url": "https://lucide.dev/license"},
]


## A link button that always opens in the system browser, never the built-in one.
func _external_link(text: String, url: String) -> Button:
	var b := UI.button(text, "external", "GhostButton", func(): OS.shell_open(url))
	b.tooltip_text = url
	return b
