class_name ReaderPopups
extends RefCounted
## The reader's two quick-settings popovers: Aa (theme, font, text size and
## spacing) and the reading-aloud one by the player (speed, pitch, pauses).

var page: ReaderPage
var _aa_node: Popover
var _tts_popup_node: Popover


func _init(p: ReaderPage) -> void:
	page = p


func show_aa() -> void:
	var btn: Control = page.main.find_child("AaButton", true, false)
	_aa_node = Popover.show_for(btn, _aa_content())


func close_aa() -> void:
	if is_instance_valid(_aa_node):
		_aa_node.close()


func _aa_content() -> Control:
	var col := UI.vbox(14)
	col.custom_minimum_size.x = 300
	col.add_child(UI.label("Theme", "Overline"))
	var themes := UI.hbox(8)
	for key in ["dark", "sepia", "light"]:
		var c: Dictionary = Settings.READER_THEMES[key]
		var b := Button.new()
		b.text = key.capitalize()
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size.y = 40
		b.add_theme_stylebox_override("normal", UiTheme.box(c.bg, 8, UiTheme.BORDER, 1))
		b.add_theme_stylebox_override("hover", UiTheme.box(c.bg, 8, UiTheme.MUTED, 1))
		b.add_theme_stylebox_override("pressed", UiTheme.box(c.bg, 8, UiTheme.ACCENT, 2))
		for k in ["font_color", "font_hover_color", "font_pressed_color"]:
			b.add_theme_color_override(k, c.text)
		b.pressed.connect(func(): Settings.set_value("reader_theme", key))
		b.set_meta("theme_key", key)
		themes.add_child(b)
	col.add_child(themes)
	col.add_child(UI.label("Font", "Overline"))
	var fonts := UI.hbox(8)
	for f in [["serif", "Literata"], ["sans", "Inter"]]:
		var b := UI.button(f[1], "", "ChipButton", func(): Settings.set_value("reader_font", f[0]))
		b.add_theme_font_override("font", UiTheme.serif if f[0] == "serif" else UiTheme.sans)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fonts.add_child(b)
	col.add_child(fonts)
	col.add_child(_stepper("Text size", "font_size", 14, 34, 1))
	col.add_child(UI.label("Alignment", "Overline"))
	col.add_child(SettingsPage.segmented_row("text_align", ReaderPage.ALIGN_OPTIONS))
	col.add_child(_stepper("Line spacing", "line_spacing", 0, 20, 2))
	col.add_child(_stepper("Paragraph spacing", "paragraph_gap", 0, 60, 2))
	col.add_child(_stepper("Text width", "column_width", 360, 1600, 40))
	col.add_child(_stepper("Side margins", "side_margin", 0, 160, 4))
	var indent := CheckButton.new()
	indent.text = "Indent first line"
	indent.focus_mode = Control.FOCUS_NONE
	indent.button_pressed = bool(Settings.get_value("first_line_indent"))
	indent.toggled.connect(func(v): Settings.set_value("first_line_indent", v))
	col.add_child(indent)
	var rules_btn := UI.button("Text & speech rules", "replace", "", func():
		close_aa()
		page.main.pages.settings.tab = 2
		page.main.navigate("settings"))
	rules_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	col.add_child(rules_btn)
	return col


func _stepper(label: String, key: String, lo: int, hi: int, step: int) -> Control:
	var row := UI.hbox(8)
	var l := UI.label(label, "Muted")
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var value := UI.label(str(int(Settings.get_value(key))), "H3")
	value.custom_minimum_size.x = 44
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var minus := UI.icon_button("chev_left", "Less", func():
		Settings.set_value(key, clampi(int(Settings.get_value(key)) - step, lo, hi)); value.text = str(int(Settings.get_value(key))))
	var plus := UI.icon_button("chev_right", "More", func():
		Settings.set_value(key, clampi(int(Settings.get_value(key)) + step, lo, hi)); value.text = str(int(Settings.get_value(key))))
	row.add_child(minus)
	row.add_child(value)
	row.add_child(plus)
	return row


func show_tts_popup(anchor: Control = null) -> void:
	var btn: Control = anchor if is_instance_valid(anchor) else page.find_child("TtsSettingsButton", true, false)
	_tts_popup_node = Popover.show_for(btn if btn else page._player, _tts_content(), true)


func close_tts_popup() -> void:
	if is_instance_valid(_tts_popup_node):
		_tts_popup_node.close()


func _tts_content() -> Control:
	var col := UI.vbox(12)
	col.custom_minimum_size.x = 340
	col.add_child(UI.label("Reading aloud", "H3"))
	col.add_child(SettingsPage.slider_row("Speed", "tts_rate", 0.5, 3.0, 0.05, "%.2fx", 140))
	col.add_child(SettingsPage.slider_row("Pitch", "tts_pitch", 0.5, 1.5, 0.05, "%.2f", 140))
	col.add_child(SettingsPage.slider_row("Paragraph pause", "tts_pause_paragraph", 0, 3000, 50, "%d ms", 140))
	col.add_child(SettingsPage.slider_row("Heading pause", "tts_pause_heading", 0, 4000, 50, "%d ms", 140))
	col.add_child(SettingsPage.slider_row("Sentence pause", "tts_pause_sentence", 0, 2000, 25, "%d ms", 140))
	col.add_child(SettingsPage.segmented_row("tts_mode", [["paragraph", "Paragraphs"], ["sentence", "Sentences"]]))
	col.add_child(UI.label("Sentence pauses apply in Sentences mode. Changes apply from the next sentence.", "Small", true))
	col.add_child(UI.button("All voice settings", "settings", "", func():
		if _tts_popup_node: _tts_popup_node.close()
		page.main.pages.settings.tab = 1
		page.main.navigate("settings")))
	return col
