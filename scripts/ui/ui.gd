class_name UI
## Small helpers for building UI in code.


static func label(text: String, variation := "", wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


static func button(text: String, icon := "", variation := "", callback := Callable(), icon_color := Color(0, 0, 0, 0)) -> Button:
	var b := Button.new()
	b.text = text
	if variation != "":
		b.theme_type_variation = variation
	if icon != "":
		var c := icon_color
		if c.a == 0:
			c = Color("#06121f") if variation == "PrimaryButton" else UiTheme.TEXT
		b.icon = Icons.get_icon(icon, c, 18)
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if callback.is_valid():
		b.pressed.connect(callback)
	return b


static func icon_button(icon: String, tooltip: String, callback := Callable(), size := 20) -> Button:
	var b := Button.new()
	b.theme_type_variation = "GhostButton"
	b.icon = Icons.get_icon(icon, UiTheme.TEXT, size)
	b.tooltip_text = tooltip
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if callback.is_valid():
		b.pressed.connect(callback)
	return b


static func hbox(sep := 8, children: Array = []) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	for c in children:
		h.add_child(c)
	return h


static func vbox(sep := 8, children: Array = []) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	for c in children:
		v.add_child(c)
	return v


static func spacer(horizontal := true) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE  # empty space shouldn't block clicks on what's underneath
	if horizontal:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


static func margin(child: Control, l := 0, t := 0, r := 0, b := 0) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	m.add_child(child)
	return m


static func panel(variation: String, child: Control = null) -> PanelContainer:
	var p := PanelContainer.new()
	p.theme_type_variation = variation
	if child:
		p.add_child(child)
	return p


static func icon(name: String, color := UiTheme.MUTED, size := 18) -> TextureRect:
	var t := TextureRect.new()
	t.texture = Icons.get_icon(name, color, size)
	t.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	t.custom_minimum_size = Vector2(size, size)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


static func chip(text: String, color := UiTheme.MUTED) -> PanelContainer:
	var l := label(text, "Small")
	l.add_theme_color_override("font_color", color)
	var p := panel("Chip", l)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return p


static func scroll(child: Control) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(child)
	return s


static func progress(value: float, height := 4) -> ProgressBar:
	var p := ProgressBar.new()
	p.show_percentage = false
	p.max_value = 1.0
	p.value = value
	p.custom_minimum_size.y = height
	return p


static func relative_time(unix: float) -> String:
	if unix <= 0:
		return "never"
	var d := Time.get_unix_time_from_system() - unix
	if d < 60: return "just now"
	if d < 3600: return "%d min ago" % int(d / 60)
	if d < 86400: return "%d h ago" % int(d / 3600)
	if d < 86400 * 30: return "%d days ago" % int(d / 86400)
	if d < 86400 * 365: return "%d months ago" % int(d / (86400 * 30))
	return "%d years ago" % int(d / (86400 * 365))


static func clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()
