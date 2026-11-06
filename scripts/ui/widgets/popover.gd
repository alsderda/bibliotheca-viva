class_name Popover
extends Control
## Lightweight in-app popover: a card placed next to an anchor control.
## Clicking outside or pressing Esc closes it. Lives in the main viewport,
## so it uses the same coordinates as the rest of the UI.

var card: PanelContainer
var _anchor: Control
var _above := false
var _left := false


## [param left] puts the card beside the anchor, to its left, where there's room,
## with a speech-bubble point aimed at the anchor.
static func show_for(anchor: Control, content: Control, above := false, left := false) -> Popover:
	var host := anchor.get_tree().root.get_child(anchor.get_tree().root.get_child_count() - 1) as Control
	var p := Popover.new()
	p._anchor = anchor
	p._above = above
	p._left = left
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(p)
	p.card = UI.panel("Card", content)
	p.card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SURFACE_2, 14, UiTheme.BORDER, 1, Vector4(18, 16, 18, 16)))
	p.add_child(p.card)
	p._place.call_deferred()
	return p


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: close())


func _place() -> void:
	card.reset_size()
	var sz := card.get_combined_minimum_size()
	var vw := get_viewport_rect().size
	if sz.y > vw.y - 16:
		_fit_height(vw.y - 16 - (sz.y - card.get_child(0).get_combined_minimum_size().y))
		card.reset_size()
		sz = card.get_combined_minimum_size()
	var a := _anchor.get_global_rect() if is_instance_valid(_anchor) else Rect2(vw / 2, Vector2.ZERO)
	var x := clampf(a.get_center().x - sz.x / 2.0, 8, vw.x - sz.x - 8)
	if not _above:
		x = clampf(a.end.x - sz.x, 8, vw.x - sz.x - 8)
	var y := a.position.y - sz.y - 10 if _above else a.end.y + 8
	if _left and a.position.x - sz.x - 8 >= 8:
		x = a.position.x - sz.x - 8
		y = a.position.y
		card.draw.connect(_draw_tail)
	card.position = Vector2(x, clampf(y, 8, vw.y - sz.y - 8))


## Puts the card's content in a scroll box of at most [param h] pixels, for content
## taller than the window.
func _fit_height(h: float) -> void:
	var content := card.get_child(0) as Control
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(content.get_combined_minimum_size().x, maxf(h, 80))
	card.remove_child(content)
	scroll.add_child(content)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_child(scroll)


## The point on the card's right edge, at the anchor's height. Drawn by the
## card itself, so it follows the card if it's moved.
func _draw_tail() -> void:
	if not is_instance_valid(_anchor):
		return
	var sb := card.get_theme_stylebox("panel") as StyleBoxFlat
	var w := card.size.x
	var y := _anchor.get_global_rect().get_center().y - card.global_position.y
	var pts := PackedVector2Array([Vector2(w - 1, y - 7), Vector2(w + 7, y), Vector2(w - 1, y + 7)])
	card.draw_colored_polygon(pts, sb.bg_color)
	card.draw_polyline(pts, sb.border_color, 1.0, true)


func close() -> void:
	queue_free()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
