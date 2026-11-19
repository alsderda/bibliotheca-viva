class_name SearchBox
extends HBoxContainer
## A page's search field for the top bar that can shrink to a search icon
## button when the bar is short of room. It only shrinks while it is empty and
## not being typed in; clicking the icon grows it back and focuses it.
## The page owns one and reuses it across top bar rebuilds (like a LineEdit).

## Emitted when it may want to change size by itself (it lost focus while
## empty), so the top bar re-checks the room and collapses it if needed.
signal refit_wanted

## The text field. Pages read its text and connect text_changed to it.
var field: LineEdit
## The icon button shown instead of the field while collapsed.
var button: Button
## Whether only the icon is shown.
var collapsed := false:
	set(value):
		collapsed = value
		if field != null:
			field.visible = not value
		if button != null:
			button.visible = value


## placeholder: the field's placeholder, also the icon's tooltip.
## width: the field's width when shown.
func _init(placeholder: String, width := 220.0) -> void:
	add_theme_constant_override("separation", 0)
	field = LineEdit.new()
	field.theme_type_variation = "SearchField"
	field.placeholder_text = placeholder
	field.custom_minimum_size.x = width
	field.right_icon = Icons.get_icon("search", UiTheme.FAINT, 18)
	field.focus_exited.connect(_on_focus_exited)
	add_child(field)
	button = UI.icon_button("search", placeholder, _expand)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.visible = false
	add_child(button)


## True while it may shrink: empty and not focused.
func can_collapse() -> bool:
	return field.text == "" and not field.has_focus()


## How much wider it gets when it grows from the icon to the field.
func grow_cost() -> float:
	return field.get_combined_minimum_size().x - button.get_combined_minimum_size().x


func _expand() -> void:
	collapsed = false
	field.grab_focus()


func _on_focus_exited() -> void:
	if field.text == "":
		refit_wanted.emit()
