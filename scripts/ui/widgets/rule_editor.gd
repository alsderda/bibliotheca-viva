class_name RuleEditor
extends Control
## Modal editor for one replacement rule, with a live test box.
## Usage: RuleEditor.open(main, rule, book_id, sample)

signal closed

var rule := {}
var is_new := true
var book_id := ""

var _name: LineEdit
var _pattern: LineEdit
var _replace: LineEdit
var _regex: CheckBox
var _case: CheckBox
var _word: CheckBox
var _scope_buttons := {}
var _book_pick: OptionButton
var _book_ids: Array = []
var _sample: TextEdit
var _out_display: Label
var _out_tts: Label
var _status: Label


static func open(host: Control, r: Dictionary, context_book := "", sample := "") -> RuleEditor:
	var ed := RuleEditor.new()
	ed.is_new = r.is_empty() or not TextRules.rules.any(func(x): return x.id == r.get("id", ""))
	ed.rule = TextRules.new_rule(r) if ed.is_new else r.duplicate()
	ed.book_id = context_book
	ed.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(ed)
	ed._build(sample)
	return ed


func _build(sample: String) -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e): if e is InputEventMouseButton and e.pressed: _close())
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var card := UI.panel("Card")
	card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SURFACE, 16, UiTheme.BORDER, 1, Vector4(24, 22, 24, 22)))
	var vw := get_viewport_rect().size.x
	card.custom_minimum_size.x = minf(640, vw - 24)
	center.add_child(card)
	var col := UI.vbox(14)
	card.add_child(col)

	var head := UI.hbox(10, [UI.icon("replace", UiTheme.ACCENT, 22), UI.label("New replacement rule" if is_new else "Edit rule", "H2")])
	head.add_child(UI.spacer())
	head.add_child(UI.icon_button("x", "Close", _close))
	col.add_child(head)

	_pattern = _field(col, "Find", rule.pattern, "Text to find, e.g. Queequeg")
	var flags := UI.hbox(16)
	_regex = _check("Regular expression", rule.regex)
	_case = _check("Ignore case", rule.ignore_case)
	_word = _check("Whole words only", rule.whole_word)
	for c in [_regex, _case, _word]:
		flags.add_child(c)
	col.add_child(flags)
	_replace = _field(col, "Replace with", rule.replace, "Leave empty to remove the match")
	var hint := UI.label("Tip: write a pronunciation the voice gets right (“Eye-shal-strom-oz”). Use a space to drop text without joining words. In regex mode, $1 inserts the first group.", "Small", true)
	col.add_child(hint)

	col.add_child(UI.label("APPLIES TO", "Overline"))
	var scopes := UI.hbox(6)
	var group := ButtonGroup.new()
	for s in [["tts", "Speech only", "mic"], ["display", "Text only", "eye"], ["both", "Text and speech", "replace"]]:
		var b := UI.button(s[1], s[2], "ChipButton", Callable(), UiTheme.MUTED)
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = rule.scope == s[0]
		b.pressed.connect(func(): rule.scope = s[0]; _refresh())
		scopes.add_child(b)
		_scope_buttons[s[0]] = b
	scopes.add_child(UI.spacer())
	_book_pick = OptionButton.new()
	_book_pick.focus_mode = Control.FOCUS_NONE
	_book_pick.add_item("All books")
	_book_ids = [""]
	for b in Library.books:
		_book_pick.add_item(b.title.left(40))
		_book_ids.append(b.id)
	var sel := _book_ids.find(rule.book if not is_new else (rule.book if rule.book != "" else book_id))
	_book_pick.select(max(0, sel))
	_book_pick.custom_minimum_size.x = 200
	scopes.add_child(_book_pick)
	col.add_child(scopes)

	col.add_child(UI.label("TEST", "Overline"))
	_sample = TextEdit.new()
	_sample.text = sample if sample != "" else "Ishmael met Queequeg. [Ship's log: day 41 (calm seas)] HP was low — but he smiled."
	_sample.custom_minimum_size.y = 64
	_sample.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_sample.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.BG, 8, UiTheme.BORDER, 1, Vector4(10, 8, 10, 8)))
	_sample.add_theme_stylebox_override("focus", UiTheme.box(UiTheme.BG, 8, UiTheme.ACCENT, 1, Vector4(10, 8, 10, 8)))
	_sample.add_theme_color_override("font_color", UiTheme.TEXT)
	_sample.text_changed.connect(_refresh)
	col.add_child(_sample)
	var outs := UI.vbox(6)
	_out_display = _output(outs, "eye", "Shown")
	_out_tts = _output(outs, "mic", "Spoken")
	col.add_child(UI.panel("CardFlat", outs))
	_status = UI.label("", "Small")
	col.add_child(_status)

	_name = _field(col, "Name (optional)", rule.name, "e.g. Pronounce the harpooneer's name")

	var buttons := UI.hbox(10)
	if not is_new:
		buttons.add_child(UI.button("Delete", "trash", "GhostButton", func(): TextRules.remove_rule(rule.id); _close(), UiTheme.BAD))
	buttons.add_child(UI.button("Speak test", "volume", "", func(): _sync(); Speech.preview(TextRules.preview(_sample.text, rule).tts)))
	buttons.add_child(UI.spacer())
	buttons.add_child(UI.button("Cancel", "", "GhostButton", _close))
	buttons.add_child(UI.button("Save rule", "check", "PrimaryButton", _save))
	col.add_child(buttons)

	for le in [_pattern, _replace]:
		le.text_changed.connect(func(_t): _refresh())
	for c in [_regex, _case, _word]:
		c.toggled.connect(func(_v): _refresh())
	_refresh()
	_pattern.grab_focus.call_deferred()


func _field(col: VBoxContainer, label: String, value: String, placeholder: String) -> LineEdit:
	col.add_child(UI.label(label.to_upper(), "Overline"))
	var le := LineEdit.new()
	le.text = value
	le.placeholder_text = placeholder
	le.custom_minimum_size.y = 40
	col.add_child(le)
	return le


func _check(text: String, value: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = value
	c.focus_mode = Control.FOCUS_NONE
	return c


func _output(parent: VBoxContainer, icon: String, label: String) -> Label:
	var row := UI.hbox(10, [UI.icon(icon, UiTheme.MUTED, 16)])
	var l := UI.label(label, "Small")
	l.custom_minimum_size.x = 56
	row.add_child(l)
	var out := UI.label("", "", true)
	out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(out)
	parent.add_child(row)
	return out


func _sync() -> void:
	rule.pattern = _pattern.text
	rule.replace = _replace.text
	rule.regex = _regex.button_pressed
	rule.ignore_case = _case.button_pressed
	rule.whole_word = _word.button_pressed
	rule.name = _name.text.strip_edges() if _name else rule.name
	rule.book = _book_ids[_book_pick.selected] if _book_pick else rule.book


func _refresh() -> void:
	if _out_tts == null:
		return
	_sync()
	if rule.pattern == "":
		_out_display.text = _sample.text
		_out_tts.text = _sample.text
		_status.text = "Type something to find."
		_status.add_theme_color_override("font_color", UiTheme.MUTED)
		return
	var p := TextRules.preview(_sample.text, rule)
	_out_display.text = p.display
	_out_tts.text = p.tts if p.tts.strip_edges() != "" else "(nothing is read aloud)"
	if p.error != "":
		_status.text = p.error
		_status.add_theme_color_override("font_color", UiTheme.BAD)
	else:
		_status.text = "%d match%s in the test text" % [p.matches, "" if p.matches == 1 else "es"]
		_status.add_theme_color_override("font_color", UiTheme.GOOD if p.matches > 0 else UiTheme.MUTED)


func _save() -> void:
	_sync()
	var err := TextRules.validate(rule)
	if err != "":
		_status.text = err
		_status.add_theme_color_override("font_color", UiTheme.BAD)
		return
	TextRules.update_rule(rule)
	_close()


func _close() -> void:
	if not Speech.playing:
		Speech.stop()
	closed.emit()
	queue_free()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
