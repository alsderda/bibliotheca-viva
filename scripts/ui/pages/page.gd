class_name Page
extends Control
## Base class for main-area pages. The shell reads title/tabs/actions from the
## page to build the top bar (secondary navigation).

signal header_changed

var main: Node
var tab := 0
var compact := false


func page_title() -> String:
	return ""


## Control shown in place of the plain title, or null for the plain title.
func title_control() -> Control:
	return null


func tabs() -> PackedStringArray:
	return []


## Page that should be highlighted in the sidebar.
func nav_key() -> String:
	return ""


func has_back() -> bool:
	return false


func go_back() -> void:
	pass


func select_tab(i: int) -> void:
	tab = i
	_on_tab(i)


func build_actions(_bar: HBoxContainer) -> void:
	pass


func on_shown() -> void:
	pass


func on_hidden() -> void:
	pass


func set_compact(value: bool) -> void:
	compact = value


func _on_tab(_i: int) -> void:
	pass
