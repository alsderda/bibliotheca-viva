class_name SettingsReading
extends SettingsSection
## The Reading tab of Settings: the reading style controls and their live preview.


func build() -> void:
	_content.add_child(UI.margin(UI.label("Text size and layout are kept per device, so your phone and computer can differ. The reader theme syncs.", "Muted", true), 6, 0, 0, 0))
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
	_section("Library", [
		_row("Cover size", "Size of the book covers in the Library. They stretch a little so each row fills the width.", _segmented("library_cover_size", [["large", "150%"], ["normal", "100%"], ["small", "67%"], ["smallest", "50%"]])),
	])
	_section("Contents", [
		_row("Chapters per group", "Long chapter lists are split into collapsible groups. When the chapter titles show where each book starts, the groups follow the books; otherwise each group has this many chapters.", _slider("contents_group_size", 10, 500, 10, "%d")),
	])


## Shows the sample paragraphs as the reader would.
func _style_preview(prev: PanelContainer, rt: RichTextLabel) -> void:
	var c := Settings.reader_colors()
	var side := float(Settings.get_value("side_margin"))
	prev.add_theme_stylebox_override("panel", UiTheme.box(c.bg, 14, UiTheme.BORDER, 1, Vector4(side, 16, side, 16) if page.compact else Vector4(side, 26, side, 26)))
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
