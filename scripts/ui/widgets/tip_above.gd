class_name TipAbove
extends Button
## Put on a button to show its tooltip above it instead of below. For buttons
## just over the native web view, which draws over every Godot control and would
## cut off a tooltip that opens downwards.
## Usage: TipAbove.apply(button)


static func apply(b: Button) -> void:
	b.set_script(TipAbove)


func _make_custom_tooltip(for_text: String) -> Object:
	var l := Label.new()
	l.theme_type_variation = "TooltipLabel"
	l.text = for_text
	# Runs after the viewport has placed the tooltip under the mouse.
	(func():
		var pop := l.get_parent() as Window
		if pop:
			pop.position.y = int(get_global_rect().position.y - pop.size.y - 4)).call_deferred()
	return l
