class_name SiteRuleEditor
extends Control
## Modal editor for one site rule (see SiteRules).
## Usage: SiteRuleEditor.open(main, rule)   (an empty rule, or {"host": ...}, makes a new one)

signal closed

const LABELS := {
	"content": ["Chapter text", "The element that holds the chapter text, e.g. .chapter-content"],
	"skip": ["Parts to skip", "Things inside the text not to read, e.g. .author-note, .ad"],
	"next": ["Next chapter link", "e.g. a.next-chap  (leave empty to look for a “Next” link)"],
	"prev": ["Previous chapter link", "e.g. a.prev-chap"],
	"title": ["Chapter title", "e.g. h1.chapter-title"],
}

var rule := {}
var is_new := true

var _host: LineEdit
var _fields := {}
var _status: Label


static func open(host: Control, r: Dictionary) -> SiteRuleEditor:
	var ed := SiteRuleEditor.new()
	ed.is_new = not SiteRules.all().any(func(x): return x.id == r.get("id", ""))
	ed.rule = SiteRules.new_rule() if ed.is_new else r.duplicate()
	if ed.is_new:
		ed.rule.merge(r, true)
	ed.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(ed)
	ed._build()
	return ed


func _build() -> void:
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
	var vp := get_viewport_rect().size
	card.custom_minimum_size.x = minf(640, vp.x - 24)
	center.add_child(card)
	var col := UI.vbox(10)
	var scroll := UI.scroll(col)
	scroll.custom_minimum_size.y = minf(640, vp.y - 48)
	card.add_child(scroll)

	var head := UI.hbox(10, [UI.icon("globe", UiTheme.ACCENT, 22), UI.label("New site rule" if is_new else "Edit site rule", "H2")])
	head.add_child(UI.spacer())
	head.add_child(UI.icon_button("x", "Close", _close))
	col.add_child(head)
	col.add_child(UI.label("Tell the Web tab where things are on this site, as CSS selectors. Fill in only what it gets wrong; empty fields keep the usual behaviour. Your rule wins over a plugin's.", "Muted", true))

	_host = _field(col, "Site", rule.host, "example.com  (also covers its subdomains)")
	for f in SiteRules.FIELDS:
		_fields[f] = _field(col, LABELS[f][0], rule[f], LABELS[f][1])
	col.add_child(UI.label("Tip: in a desktop browser, right-click the part you mean, choose Inspect, then right-click the highlighted element and Copy → Copy selector.", "Small", true))
	_status = UI.label("", "Small")
	col.add_child(_status)

	var buttons := UI.hbox(10)
	if not is_new:
		buttons.add_child(UI.button("Delete", "trash", "GhostButton", func(): SiteRules.remove(rule.id); _close(), UiTheme.BAD))
	buttons.add_child(UI.spacer())
	buttons.add_child(UI.button("Cancel", "", "GhostButton", _close))
	buttons.add_child(UI.button("Save rule", "check", "PrimaryButton", _save))
	col.add_child(buttons)
	(_fields.content if rule.host != "" else _host).grab_focus.call_deferred()


func _field(col: VBoxContainer, label: String, value: String, placeholder: String) -> LineEdit:
	col.add_child(UI.label(label.to_upper(), "Overline"))
	var le := LineEdit.new()
	le.text = value
	le.placeholder_text = placeholder
	le.custom_minimum_size.y = 40
	le.add_theme_font_override("font", UiTheme.mono)
	col.add_child(le)
	return le


func _save() -> void:
	rule.host = _host.text
	for f in SiteRules.FIELDS:
		rule[f] = _fields[f].text
	var err := SiteRules.validate(rule)
	if err != "":
		_status.text = err
		_status.add_theme_color_override("font_color", UiTheme.BAD)
		return
	SiteRules.save(rule)
	_close()


func _close() -> void:
	closed.emit()
	queue_free()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
