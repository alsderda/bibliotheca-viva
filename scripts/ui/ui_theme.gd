class_name UiTheme
## App-wide colors, fonts and the Godot Theme built from them.

const BG := Color("#0e1014")
const SIDEBAR := Color("#13161b")
const SURFACE := Color("#181b21")
const SURFACE_2 := Color("#20242c")
const SURFACE_3 := Color("#2a2f39")
const BORDER := Color("#262b34")
const TEXT := Color("#e7e9ee")
const MUTED := Color("#949cab")
const FAINT := Color("#666e7c")
const ACCENT := Color("#5aa9ff")
const ACCENT_DIM := Color(0.353, 0.663, 1.0, 0.14)
const GOOD := Color("#4ade80")
const WARN := Color("#f5b454")
const BAD := Color("#f87171")

static var sans: Font
static var sans_medium: Font
static var sans_semibold: Font
static var sans_bold: Font
static var serif: Font
static var serif_bold: Font
static var serif_italic: Font
static var mono: Font


static func load_fonts() -> void:
	if sans:
		return
	var inter: FontFile = load("res://assets/fonts/Inter.ttf")
	var literata: FontFile = load("res://assets/fonts/Literata.ttf")
	for f in [inter, literata]:
		f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		f.hinting = TextServer.HINTING_LIGHT
		f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
		f.oversampling = 0.0
	sans = _weight(inter, 420)
	sans_medium = _weight(inter, 520)
	sans_semibold = _weight(inter, 620)
	sans_bold = _weight(inter, 720)
	serif = _weight(literata, 400)
	serif_bold = _weight(literata, 650)
	serif_italic = _weight(literata, 400)
	var m := SystemFont.new()
	m.font_names = PackedStringArray(["SF Mono", "Menlo", "Consolas", "Cascadia Mono", "DejaVu Sans Mono", "Roboto Mono", "monospace"])
	mono = m
	(serif_italic as FontVariation).variation_transform = Transform2D(Vector2(1, 0), Vector2(0.2, 1), Vector2.ZERO)


static func _weight(base: FontFile, w: int) -> FontVariation:
	var v := FontVariation.new()
	v.base_font = base
	v.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): w}
	return v


static func box(color: Color, radius := 8, border := Color.TRANSPARENT, border_w := 0, pad := Vector4(0, 0, 0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.corner_detail = 6
	if border_w > 0:
		s.border_color = border
		s.set_border_width_all(border_w)
	s.content_margin_left = pad.x
	s.content_margin_top = pad.y
	s.content_margin_right = pad.z
	s.content_margin_bottom = pad.w
	s.anti_aliasing = true
	return s


static func build() -> Theme:
	load_fonts()
	var t := Theme.new()
	t.default_font = sans
	t.default_font_size = 14

	# Base controls
	t.set_color("font_color", "Label", TEXT)
	t.set_stylebox("panel", "Panel", box(BG, 0))
	t.set_stylebox("panel", "PanelContainer", box(Color.TRANSPARENT, 0))

	for type in ["Button", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", type, box(SURFACE_2, 8, BORDER, 1, Vector4(14, 8, 14, 8)))
		t.set_stylebox("hover", type, box(SURFACE_3, 8, BORDER, 1, Vector4(14, 8, 14, 8)))
		t.set_stylebox("pressed", type, box(SURFACE_3, 8, ACCENT, 1, Vector4(14, 8, 14, 8)))
		t.set_stylebox("disabled", type, box(SURFACE, 8, BORDER, 1, Vector4(14, 8, 14, 8)))
		t.set_stylebox("focus", type, box(Color.TRANSPARENT, 8, Color(ACCENT, 0.6), 1))
		t.set_color("font_color", type, TEXT)
		t.set_color("font_hover_color", type, TEXT)
		t.set_color("font_pressed_color", type, TEXT)
		t.set_color("font_disabled_color", type, FAINT)
		t.set_color("icon_normal_color", type, TEXT)
		t.set_color("icon_hover_color", type, TEXT)
		t.set_color("icon_pressed_color", type, TEXT)
		t.set_font("font", type, sans_medium)
		t.set_constant("h_separation", type, 8)
	t.set_font("font", "Button", sans_medium)

	# Variations
	_variation(t, "PrimaryButton", "Button", {
		"normal": box(ACCENT, 8, Color.TRANSPARENT, 0, Vector4(16, 9, 16, 9)),
		"hover": box(ACCENT.lightened(0.12), 8, Color.TRANSPARENT, 0, Vector4(16, 9, 16, 9)),
		"pressed": box(ACCENT.darkened(0.1), 8, Color.TRANSPARENT, 0, Vector4(16, 9, 16, 9)),
	}, {"font_color": Color("#06121f"), "font_hover_color": Color("#06121f"), "font_pressed_color": Color("#06121f"), "icon_normal_color": Color("#06121f"), "icon_hover_color": Color("#06121f")})
	t.set_font("font", "PrimaryButton", sans_semibold)

	var ghost_pad := Vector4(10, 7, 10, 7)
	_variation(t, "GhostButton", "Button", {
		"normal": box(Color.TRANSPARENT, 8, Color.TRANSPARENT, 0, ghost_pad),
		"hover": box(SURFACE_2, 8, Color.TRANSPARENT, 0, ghost_pad),
		"pressed": box(SURFACE_3, 8, Color.TRANSPARENT, 0, ghost_pad),
		"hover_pressed": box(SURFACE_3, 8, Color.TRANSPARENT, 0, ghost_pad),
	}, {"font_color": MUTED, "font_hover_color": TEXT, "font_pressed_color": TEXT, "icon_normal_color": MUTED, "icon_hover_color": TEXT, "icon_pressed_color": TEXT})

	var nav_pad := Vector4(12, 10, 12, 10)
	_variation(t, "NavButton", "Button", {
		"normal": box(Color.TRANSPARENT, 10, Color.TRANSPARENT, 0, nav_pad),
		"hover": box(SURFACE_2, 10, Color.TRANSPARENT, 0, nav_pad),
		"pressed": box(ACCENT_DIM, 10, Color.TRANSPARENT, 0, nav_pad),
		"hover_pressed": box(ACCENT_DIM, 10, Color.TRANSPARENT, 0, nav_pad),
	}, {"font_color": MUTED, "font_hover_color": TEXT, "font_pressed_color": TEXT, "font_hover_pressed_color": TEXT,
		"icon_normal_color": MUTED, "icon_hover_color": TEXT, "icon_pressed_color": ACCENT, "icon_hover_pressed_color": ACCENT})
	t.set_font("font", "NavButton", sans_medium)
	t.set_font_size("font_size", "NavButton", 14)
	t.set_constant("h_separation", "NavButton", 12)

	# Secondary nav tabs (top bar): text with an accent underline when selected.
	var tab_normal := box(Color.TRANSPARENT, 0, Color.TRANSPARENT, 0, Vector4(4, 18, 4, 16))
	var tab_sel := box(Color.TRANSPARENT, 0, ACCENT, 0, Vector4(4, 18, 4, 16))
	tab_sel.border_width_bottom = 2
	tab_sel.border_color = ACCENT
	var tab_hover := tab_normal.duplicate()
	tab_hover.border_width_bottom = 2
	tab_hover.border_color = SURFACE_3
	_variation(t, "TabButton", "Button", {
		"normal": tab_normal, "hover": tab_hover, "pressed": tab_sel, "hover_pressed": tab_sel,
	}, {"font_color": MUTED, "font_hover_color": TEXT, "font_pressed_color": TEXT, "font_hover_pressed_color": TEXT})
	t.set_font("font", "TabButton", sans_medium)

	_variation(t, "ChipButton", "Button", {
		"normal": box(SURFACE_2, 99, BORDER, 1, Vector4(12, 5, 12, 5)),
		"hover": box(SURFACE_3, 99, BORDER, 1, Vector4(12, 5, 12, 5)),
		"pressed": box(ACCENT_DIM, 99, ACCENT, 1, Vector4(12, 5, 12, 5)),
		"hover_pressed": box(ACCENT_DIM, 99, ACCENT, 1, Vector4(12, 5, 12, 5)),
	}, {"font_color": MUTED, "font_hover_color": TEXT, "font_pressed_color": TEXT, "font_hover_pressed_color": TEXT})
	t.set_font_size("font_size", "ChipButton", 13)

	# Inputs
	t.set_stylebox("normal", "LineEdit", box(SURFACE, 8, BORDER, 1, Vector4(12, 8, 12, 8)))
	t.set_stylebox("focus", "LineEdit", box(Color.TRANSPARENT, 8, ACCENT, 1))
	t.set_stylebox("read_only", "LineEdit", box(SURFACE, 8, BORDER, 1, Vector4(12, 8, 12, 8)))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", FAINT)
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_color("selection_color", "LineEdit", Color(ACCENT, 0.35))
	_variation(t, "SearchField", "LineEdit", {"normal": box(SURFACE_2, 10, BORDER, 1, Vector4(38, 10, 12, 10))}, {})

	# Popups
	t.set_stylebox("panel", "PopupMenu", box(SURFACE_2, 10, BORDER, 1, Vector4(6, 6, 6, 6)))
	t.set_stylebox("hover", "PopupMenu", box(SURFACE_3, 6))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", TEXT)
	t.set_constant("v_separation", "PopupMenu", 8)
	t.set_stylebox("panel", "PopupPanel", box(SURFACE_2, 12, BORDER, 1, Vector4(16, 16, 16, 16)))
	t.set_stylebox("panel", "TooltipPanel", box(SURFACE_3, 6, BORDER, 1, Vector4(8, 5, 8, 5)))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_stylebox("panel", "AcceptDialog", box(SURFACE_2, 12, BORDER, 1, Vector4(16, 16, 16, 16)))

	# Sliders / progress / scrollbars
	var track := box(SURFACE_3, 3, Color.TRANSPARENT, 0, Vector4(0, 3, 0, 3))
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", box(ACCENT, 3, Color.TRANSPARENT, 0, Vector4(0, 3, 0, 3)))
	t.set_stylebox("grabber_area_highlight", "HSlider", box(ACCENT, 3, Color.TRANSPARENT, 0, Vector4(0, 3, 0, 3)))
	var grab := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for x in 16:
		for y in 16:
			var d := Vector2(x - 7.5, y - 7.5).length()
			grab.set_pixel(x, y, Color(1, 1, 1, clampf(7.5 - d, 0, 1)))
	var grab_tex := ImageTexture.create_from_image(grab)
	t.set_icon("grabber", "HSlider", grab_tex)
	t.set_icon("grabber_highlight", "HSlider", grab_tex)
	t.set_stylebox("background", "ProgressBar", box(SURFACE_3, 3))
	t.set_stylebox("fill", "ProgressBar", box(ACCENT, 3))
	for sb in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sb, box(Color.TRANSPARENT, 4, Color.TRANSPARENT, 0, Vector4(3, 3, 3, 3)))
		t.set_stylebox("grabber", sb, box(Color(1, 1, 1, 0.10), 4))
		t.set_stylebox("grabber_highlight", sb, box(Color(1, 1, 1, 0.18), 4))
		t.set_stylebox("grabber_pressed", sb, box(Color(1, 1, 1, 0.24), 4))
	t.set_color("font_color", "CheckBox", TEXT)
	t.set_color("font_color", "CheckButton", TEXT)
	t.set_color("font_hover_color", "CheckButton", TEXT)
	t.set_color("font_pressed_color", "CheckButton", TEXT)
	t.set_stylebox("normal", "CheckButton", box(Color.TRANSPARENT, 0))
	t.set_stylebox("hover", "CheckButton", box(Color.TRANSPARENT, 0))
	t.set_stylebox("pressed", "CheckButton", box(Color.TRANSPARENT, 0))
	t.set_stylebox("hover_pressed", "CheckButton", box(Color.TRANSPARENT, 0))
	t.set_stylebox("focus", "CheckButton", box(Color.TRANSPARENT, 0))
	var on := _switch(ACCENT, Color.WHITE, true)
	var off := _switch(Color("#3a414e"), Color("#b4bbc8"), false)
	var on_dis := _switch(Color(ACCENT, 0.4), Color(1, 1, 1, 0.6), true)
	var off_dis := _switch(Color("#3a414e", 0.5), Color("#b4bbc8", 0.4), false)
	for suffix in ["", "_mirrored"]:
		t.set_icon("checked" + suffix, "CheckButton", on)
		t.set_icon("unchecked" + suffix, "CheckButton", off)
		t.set_icon("checked_disabled" + suffix, "CheckButton", on_dis)
		t.set_icon("unchecked_disabled" + suffix, "CheckButton", off_dis)

	# Text variations
	_label(t, "H1", sans_bold, 26, TEXT)
	_label(t, "H2", sans_semibold, 18, TEXT)
	_label(t, "H3", sans_semibold, 15, TEXT)
	_label(t, "Muted", sans, 14, MUTED)
	_label(t, "Small", sans, 12, MUTED)
	_label(t, "Overline", sans_semibold, 11, FAINT)
	_label(t, "AccentLabel", sans_semibold, 12, ACCENT)

	# Panels
	_panel(t, "Sidebar", box(SIDEBAR, 0, Color.TRANSPARENT, 0, Vector4(12, 16, 12, 14)))
	var top := box(BG, 0, BORDER, 0, Vector4(28, 0, 20, 0))
	top.border_width_bottom = 1
	top.border_color = BORDER
	_panel(t, "Topbar", top)
	_panel(t, "Card", box(SURFACE, 14, BORDER, 1, Vector4(20, 18, 20, 18)))
	_panel(t, "CardFlat", box(SURFACE, 12, Color.TRANSPARENT, 0, Vector4(14, 12, 14, 12)))
	_panel(t, "Row", box(Color.TRANSPARENT, 10, Color.TRANSPARENT, 0, Vector4(12, 10, 12, 10)))
	_panel(t, "Badge", box(Color(0, 0, 0, 0.55), 6, Color.TRANSPARENT, 0, Vector4(7, 2, 7, 2)))
	_panel(t, "Chip", box(SURFACE_2, 99, BORDER, 1, Vector4(10, 3, 10, 3)))
	_panel(t, "Banner", box(Color(WARN, 0.10), 10, Color(WARN, 0.35), 1, Vector4(14, 10, 14, 10)))
	_panel(t, "PlayerBar", box(SURFACE, 16, BORDER, 1, Vector4(14, 10, 18, 10)))
	return t


## A 40x22 switch drawn at 2x so it stays sharp on high-DPI screens.
static func _switch(track: Color, knob: Color, knob_right: bool) -> ImageTexture:
	const S := 2
	var w := 40 * S
	var h := 22 * S
	var r := h / 2.0
	var kr := 8.0 * S
	var kx := (w - r) if knob_right else r
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for x in w:
		for y in h:
			var p := Vector2(x + 0.5, y + 0.5)
			var cx := clampf(p.x, r, w - r)
			var track_a := clampf(r - p.distance_to(Vector2(cx, r)) + 0.5, 0, 1)
			var knob_a := clampf(kr - p.distance_to(Vector2(kx, r)) + 0.5, 0, 1)
			var c := Color(track, track.a * track_a)
			c = c.blend(Color(knob, knob.a * knob_a)) if knob_a > 0 else c
			img.set_pixel(x, y, c)
	var tex := ImageTexture.create_from_image(img)
	tex.set_size_override(Vector2i(w / S, h / S))
	return tex


static func _variation(t: Theme, name: String, base: String, styles: Dictionary, colors: Dictionary) -> void:
	t.set_type_variation(name, base)
	for k in styles:
		t.set_stylebox(k, name, styles[k])
	for k in colors:
		t.set_color(k, name, colors[k])


static func _label(t: Theme, name: String, font: Font, size: int, color: Color) -> void:
	t.set_type_variation(name, "Label")
	t.set_font("font", name, font)
	t.set_font_size("font_size", name, size)
	t.set_color("font_color", name, color)


static func _panel(t: Theme, name: String, style: StyleBox) -> void:
	t.set_type_variation(name, "PanelContainer")
	t.set_stylebox("panel", name, style)
