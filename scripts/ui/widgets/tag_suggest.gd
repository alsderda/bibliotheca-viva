class_name TagSuggest
extends HFlowContainer
## Chip buttons completing what a LineEdit is typing, from the tags the app knows.
## Usage: TagSuggest.attach(edit, tags_source, single) and add the returned
## container under the field. tags_source.call() returns [all, skip]: candidate
## tags and extra tags never to offer (on top of the tags already in the field).
## single = true for a field holding ONE tag: the typed text is the whole field
## and completing replaces it with no trailing ", ".
## Emits completed(tag) after a completion so the owner can save.
## Emits refreshed after every refresh (an owner sizing itself can listen).

signal completed(tag: String)
signal refreshed

## When true the chips show only while the field has focus, so a list of many
## rows isn't cluttered; when false they stay up with "Add:" while not typing.
var only_while_focused := false
## True while a tag is being typed (the text changed since the field got focus).
var _typing := false
## Matching tags shown under the field, best first.
var _matches: Array = []
var _edit: LineEdit
var _source: Callable
var _single := false


## Creates the container, hooks it to the field's signals and returns it; the
## caller adds it to the tree under the field.
static func attach(edit: LineEdit, tags_source: Callable, single := false) -> TagSuggest:
	var s := TagSuggest.new()
	s._edit = edit
	s._source = tags_source
	s._single = single
	s.add_theme_constant_override("h_separation", 6)
	s.add_theme_constant_override("v_separation", 6)
	edit.text_changed.connect(s._on_text_changed)
	edit.focus_entered.connect(s._on_focus_entered)
	edit.focus_exited.connect(s._on_focus_exited)
	edit.gui_input.connect(s._on_edit_key)
	s.refresh.call_deferred()
	return s


## Index of the comma-separated tag the caret is in.
static func typed_index(text: String, caret: int) -> int:
	return text.substr(0, caret).count(",")


## What the field is typing right now ("", when not typing).
static func typed_now(text: String, caret: int, typing: bool, single: bool) -> String:
	if not typing:
		return ""
	if single:
		return text.strip_edges()
	var parts := text.split(",")
	return parts[clampi(typed_index(text, caret), 0, parts.size() - 1)].strip_edges()


## [text, caret] the field gets when `tag` completes what is typed.
static func completed_text(text: String, caret: int, tag: String, typing: bool, single: bool) -> Array:
	if single:
		return [tag, tag.length()]
	var parts := Array(text.split(","))
	var at := typed_index(text, caret) if typing else parts.size()
	var before := BookTags.clean_tags(parts.slice(0, at) + [tag])
	var after := parts.slice(at + 1)
	var all := BookTags.clean_tags(before + after)
	var done := ", ".join(PackedStringArray(all))
	if all.size() == before.size():  # nothing after it: ready for the next tag
		done += ", "
	return [done, mini(", ".join(PackedStringArray(before)).length() + 2, done.length())]


func refresh() -> void:
	if not is_instance_valid(_edit):
		return
	if only_while_focused and not _edit.has_focus():
		visible = false
		return
	var typed := typed_now(_edit.text, _edit.caret_column, _typing, _single)
	var got: Array = _source.call() if _source.is_valid() else [[], []]
	var all: Array = got[0] if got.size() > 0 else []
	var extra: Array = got[1] if got.size() > 1 else []
	var have: Array
	if _single:
		have = extra
	elif _typing:
		var parts := Array(_edit.text.split(","))
		var rest := parts.duplicate()
		rest.remove_at(clampi(typed_index(_edit.text, _edit.caret_column), 0, parts.size() - 1))
		have = BookTags.clean_tags(rest) + BookTags.clean_tags(extra)
	else:
		have = BookTags.clean_tags(Array(_edit.text.split(","))) + BookTags.clean_tags(extra)
	_matches = BookTags.match_tags(all, have, typed).slice(0, 12)
	UI.clear(self)
	if not _matches.is_empty():
		var hint := "Add:" if typed == "" else ("Matches:" if OS.has_feature("mobile") else "Tab to complete:")
		add_child(UI.label(hint, "Small"))
		for tag in _matches:
			var chip := UI.button(str(tag), "plus", "ChipButton", func(): _complete(str(tag)), UiTheme.MUTED)
			# Fired on press so a click still lands when it moves focus: a
			# focus change rebuilds some owners (the Tags tab) under the mouse.
			# Set twice: the app's scroll helper turns buttons under a scroll
			# back to release mode a frame later, which would lose the click.
			chip.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
			add_child(chip)
			chip.set_deferred("action_mode", BaseButton.ACTION_MODE_BUTTON_PRESS)
	visible = not _matches.is_empty()
	refreshed.emit()


## Puts `tag` in place of the one being typed (or after the others when nothing
## is) and moves the caret after it.
func _complete(tag: String) -> void:
	var was_typing := _typing
	var done: Array = completed_text(_edit.text, _edit.caret_column, tag, _typing, _single)
	_edit.text = done[0]
	_edit.caret_column = done[1]
	if only_while_focused or was_typing:
		_edit.grab_focus()
	_typing = false
	refresh()
	completed.emit(tag)


## Tab completes the tag being typed with the first match.
func _on_edit_key(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and event.keycode == KEY_TAB and not event.shift_pressed):
		return
	if not _typing or _matches.is_empty():
		return
	if typed_now(_edit.text, _edit.caret_column, _typing, _single) == "":
		return
	_complete(_matches[0])
	_edit.accept_event()


func _on_text_changed(_t: String) -> void:
	_typing = true
	refresh()


func _on_focus_entered() -> void:
	refresh()


func _on_focus_exited() -> void:
	if only_while_focused:
		_hide_soon.call_deferred()
		return
	_typing = false
	refresh()


## Deferred so a chip press (fired on press) still lands first when the click
## moved focus; skipped when focus already came back (a completion grabs it).
func _hide_soon() -> void:
	if is_instance_valid(_edit) and _edit.has_focus():
		return
	_typing = false
	visible = false
