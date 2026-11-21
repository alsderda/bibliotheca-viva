class_name SelectionBar
extends PanelContainer
## A small floating pill of touch-sized buttons, shown after text is selected
## on a touch screen. The bar positions itself above the anchor (below it when
## there is no room above), stays inside the given bounds, and hides itself
## after any button press.


signal action(id: int)

var _row: HBoxContainer


func _ready() -> void:
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 4)
	add_child(_row)
	# Raised pill: same surface as other popups, with a shadow so it reads
	# as floating over the text (UiTheme.box sets no shadow of its own).
	var sb := UiTheme.box(UiTheme.SURFACE_2, 22, UiTheme.BORDER, 1, Vector4(8, 6, 8, 6))
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0, 4)
	add_theme_stylebox_override("panel", sb)


## Shows the bar with [param actions] (an Array of {id, text, icon}) near
## [param anchor] (in the bar's parent coordinates), clamped inside [param bounds].
func show_at(anchor: Vector2, bounds: Rect2, actions: Array) -> void:
	if actions.is_empty():
		hide()
		return
	for c in _row.get_children():
		_row.remove_child(c)
		c.queue_free()
	for a in actions:
		var d: Dictionary = a
		var id := int(d.get("id", 0))
		var b := UI.button(String(d.get("text", "")), String(d.get("icon", "")), "GhostButton",
			func(): action.emit(id); hide())
		b.custom_minimum_size = Vector2(0, 44)
		_row.add_child(b)
	show()
	var want := get_combined_minimum_size()
	var w := minf(want.x, maxf(bounds.size.x - 16, 44))
	var x := clampf(anchor.x - w * 0.5, bounds.position.x + 8,
		maxf(bounds.position.x + 8, bounds.end.x - w - 8))
	var y := anchor.y - want.y - 10
	if y < bounds.position.y + 4:
		y = anchor.y + 14
	y = clampf(y, bounds.position.y + 4, maxf(bounds.position.y + 4, bounds.end.y - want.y - 4))
	position = Vector2(x, y)
	size = Vector2(w, want.y)
