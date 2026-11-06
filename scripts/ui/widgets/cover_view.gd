class_name CoverView
extends Control
## Book cover with rounded corners. Uses the stored cover image, or draws a
## generated cover (colour from the title) when there is none.

const SHADER := """
shader_type canvas_item;
uniform float radius = 8.0;
uniform vec2 size = vec2(100.0, 150.0);
void fragment() {
	vec2 p = UV * size;
	vec2 q = abs(p - size * 0.5) - (size * 0.5 - vec2(radius));
	float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	COLOR = texture(TEXTURE, UV);
	COLOR.a *= clamp(0.5 - d, 0.0, 1.0);
}
"""
const PALETTES := [
	["#3b2f63", "#7c5cbf"], ["#1f4e5f", "#3aa0a8"], ["#5f2a2a", "#c0584a"], ["#2d4a2b", "#6fa35b"],
	["#4a3a1f", "#c39445"], ["#1f2d5f", "#4f78d1"], ["#4f1f4a", "#b5539f"], ["#2b3440", "#6b7a8f"],
]

static var _shader: Shader
static var _tex_cache := {}

var radius := 8.0
var _texture: Texture2D
var _title_label: Label
var _full_title := ""
var _author_label: Label


func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	material = ShaderMaterial.new()
	material.shader = _shader
	resized.connect(_update_shader)


func set_book(book: Dictionary) -> void:
	var path: String = book.get("cover", "")
	_texture = null
	if path != "":
		_texture = _load_cropped(path)
	if _texture == null:
		_texture = _gradient(book.get("title", "?"))
		_ensure_labels()
		_full_title = book.get("title", "")
		_author_label.text = book.get("author", "")
		_title_label.show()
		_update_shader()
	elif _title_label:
		_title_label.hide()
		_author_label.hide()
	queue_redraw()


func _ensure_labels() -> void:
	if _title_label:
		return
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_label = Label.new()
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title_label.add_theme_font_override("font", UiTheme.serif_bold)
	_title_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title_label.max_lines_visible = 4
	_author_label = Label.new()
	_author_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	_author_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_title_label)
	box.add_child(UI.spacer(false))
	box.add_child(_author_label)
	var m := UI.margin(box, 12, 38, 12, 12)
	m.name = "TitleMargin"
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(m)
	_update_shader()


func _update_shader() -> void:
	(material as ShaderMaterial).set_shader_parameter("size", size)
	(material as ShaderMaterial).set_shader_parameter("radius", radius)
	if _title_label:
		var small := size.x < 90
		var m: MarginContainer = _title_label.get_parent().get_parent()
		m.add_theme_constant_override("margin_top", int(size.y * 0.22) if small else 38)
		m.add_theme_constant_override("margin_left", 0 if small else 12)
		m.add_theme_constant_override("margin_right", 0 if small else 12)
		_title_label.text = _full_title.left(1).to_upper() if small else _full_title
		_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if small else HORIZONTAL_ALIGNMENT_LEFT
		_title_label.add_theme_font_size_override("font_size", int(size.x * 0.42) if small else clampi(int(size.x / 8.5), 11, 22))
		_author_label.visible = not small and _author_label.text != ""
		_author_label.add_theme_font_size_override("font_size", clampi(int(size.x / 13.0), 9, 14))


func _draw() -> void:
	if _texture:
		draw_texture_rect(_texture, Rect2(Vector2.ZERO, size), false)


static func _load_cropped(path: String) -> Texture2D:
	# a book keeps its cover path when the cover changes, so key by the file's time too
	var key := "%s@%d" % [path, FileAccess.get_modified_time(path)]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	var target := 2.0 / 3.0
	var w := img.get_width()
	var h := img.get_height()
	if float(w) / h > target:
		var nw := int(h * target)
		img = img.get_region(Rect2i((w - nw) / 2, 0, nw, h))
	elif float(w) / h < target - 0.02:
		var nh := int(w / target)
		img = img.get_region(Rect2i(0, (h - nh) / 2, w, nh))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


static func _gradient(title: String) -> Texture2D:
	var pal: Array = PALETTES[abs(title.hash()) % PALETTES.size()]
	var key: String = pal[0]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var g := Gradient.new()
	g.set_color(0, Color(pal[1]))
	g.set_color(1, Color(pal[0]))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_LINEAR
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(0.6, 1)
	t.width = 128
	t.height = 192
	_tex_cache[key] = t
	return t
