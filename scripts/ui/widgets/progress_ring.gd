class_name ProgressRing
extends Control
## A small circular progress indicator: a faint ring filled clockwise from the top.

## 0 to 1.
var value := 0.0:
	set(v):
		value = clampf(v, 0.0, 1.0)
		queue_redraw()


func _init(size := 16) -> void:
	custom_minimum_size = Vector2(size, size)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_PASS


func _draw() -> void:
	var width := 2.5
	var c := size / 2.0
	var r := minf(size.x, size.y) / 2.0 - width / 2.0
	draw_arc(c, r, 0.0, TAU, 48, UiTheme.SURFACE_3, width, true)
	if value > 0.0:
		draw_arc(c, r, -PI / 2.0, -PI / 2.0 + TAU * value, maxi(4, int(48 * value)), UiTheme.ACCENT, width, true)
