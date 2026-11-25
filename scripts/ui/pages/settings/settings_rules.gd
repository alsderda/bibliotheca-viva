class_name SettingsRules
extends SettingsSection
## The Text rules tab of Settings: the replacement rules applied to text before it is read aloud or shown.


func build() -> void:
	var intro := UI.vbox(10)
	var head := UI.hbox(10)
	var title := UI.vbox(2)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_child(UI.label("Text and speech rules", "H3"))
	title.add_child(UI.label("Find-and-replace rules run on every chapter. Use them to fix how names are pronounced, keep things from being read aloud, or clean up the text. Rules run top to bottom.", "Muted", true))
	head.add_child(title)
	intro.add_child(head)
	var actions := HFlowContainer.new()
	actions.add_theme_constant_override("h_separation", 8)
	actions.add_theme_constant_override("v_separation", 8)
	actions.add_child(UI.button("New rule", "plus", "PrimaryButton", func(): RuleEditor.open(page.main, {})))
	var examples := MenuButton.new()
	examples.text = "Add example"
	examples.icon = Icons.get_icon("sparkle", UiTheme.TEXT, 18)
	examples.flat = false
	examples.focus_mode = Control.FOCUS_NONE
	for i in TextRules.EXAMPLES.size():
		examples.get_popup().add_item(TextRules.EXAMPLES[i].name, i)
	examples.get_popup().id_pressed.connect(func(i): TextRules.add_rule(TextRules.new_rule(TextRules.EXAMPLES[i])); page.main.toast("Added “%s”" % TextRules.EXAMPLES[i].name, "ok"))
	actions.add_child(examples)
	actions.add_child(UI.button("Copy all", "copy", "", func(): DisplayServer.clipboard_set(TextRules.export_json()); page.main.toast("Rules copied to the clipboard as JSON", "ok")))
	actions.add_child(UI.button("Paste rules", "clipboard", "", func():
		var n := TextRules.import_json(DisplayServer.clipboard_get())
		page.main.toast("Clipboard doesn't contain rules" if n < 0 else "Imported %d rule(s)" % n, "warn" if n < 0 else "ok")))
	intro.add_child(actions)
	var card := UI.panel("Card", intro)
	_content.add_child(card)

	if TextRules.rules.is_empty():
		var empty := UI.vbox(6)
		empty.add_child(UI.label("No rules yet", "H3"))
		empty.add_child(UI.label("Tip: in the reader, select a word and right-click it to fix its pronunciation.", "Muted", true))
		_content.add_child(UI.margin(empty, 6, 10, 0, 0))
	else:
		var list := UI.vbox(4)
		for i in TextRules.rules.size():
			list.add_child(_rule_row(TextRules.rules[i], i))
		_content.add_child(UI.panel("Card", list))

	# Try all rules
	var tester := UI.vbox(10)
	tester.add_child(UI.label("Try your rules", "H3"))
	var input := TextEdit.new()
	input.text = "“Queequeg!” Ishmael shouted. [Ship's log: day 41]\n* * *\nThe whale's HP dropped — fast."
	input.custom_minimum_size.y = 76
	input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	input.add_theme_stylebox_override("normal", UiTheme.box(UiTheme.BG, 8, UiTheme.BORDER, 1, Vector4(10, 8, 10, 8)))
	input.add_theme_stylebox_override("focus", UiTheme.box(UiTheme.BG, 8, UiTheme.ACCENT, 1, Vector4(10, 8, 10, 8)))
	input.add_theme_color_override("font_color", UiTheme.TEXT)
	tester.add_child(input)
	var shown := UI.label("", "", true)
	var spoken := UI.label("", "", true)
	shown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spoken.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var out := UI.vbox(6, [UI.hbox(10, [UI.icon("eye"), _fixed_label("Shown"), shown]), UI.hbox(10, [UI.icon("mic"), _fixed_label("Spoken"), spoken])])
	tester.add_child(UI.panel("CardFlat", out))
	var update := func():
		var lines_shown := PackedStringArray()
		var lines_spoken := PackedStringArray()
		for line in input.text.split("\n"):
			var d := HtmlText.plain(TextRules.apply_display(line.replace("[", "\u0002").replace("]", "[rb]").replace("\u0002", "[lb]")))
			var t := TextRules.apply_tts(line).strip_edges()
			lines_shown.append(d if d.strip_edges() != "" else "(hidden)")
			if t != "":
				lines_spoken.append(t)
		shown.text = "\n".join(lines_shown)
		spoken.text = " … ".join(lines_spoken) if lines_spoken.size() > 0 else "(nothing)"
	input.text_changed.connect(update)
	update.call()
	var speak := UI.button("Speak result", "volume", "", func(): Speech.preview(spoken.text.replace(" … ", ". ")))
	speak.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tester.add_child(speak)
	_content.add_child(UI.panel("Card", tester))


func _fixed_label(t: String) -> Label:
	var l := UI.label(t, "Small")
	l.custom_minimum_size.x = 52
	return l


func _rule_row(r: Dictionary, index: int) -> Control:
	var row := UI.hbox(12)
	var on := CheckButton.new()
	on.button_pressed = r.enabled
	on.focus_mode = Control.FOCUS_NONE
	on.tooltip_text = "Enabled"
	on.toggled.connect(func(v): TextRules.set_enabled(r.id, v))
	on.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(on)
	var info := UI.vbox(3)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_l := UI.label(r.name if r.name != "" else r.pattern, "H3")
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_l.custom_minimum_size.x = 80
	if not r.enabled:
		name_l.add_theme_color_override("font_color", UiTheme.FAINT)
	info.add_child(name_l)
	var detail := UI.label("%s  →  %s" % [r.pattern, _show_replacement(r.replace)], "Small")
	detail.add_theme_font_override("font", UiTheme.mono)
	detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	detail.custom_minimum_size.x = 80
	info.add_child(detail)
	var chips := _chip_row()
	var scope_color: Color = {"tts": UiTheme.ACCENT, "display": UiTheme.WARN, "both": UiTheme.GOOD}[r.scope]
	chips.add_child(UI.chip(TextRules.SCOPE_NAMES[r.scope], scope_color))
	if r.regex:
		chips.add_child(UI.chip("regex"))
	if r.ignore_case:
		chips.add_child(UI.chip("any case"))
	if r.whole_word:
		chips.add_child(UI.chip("whole word"))
	var b := Library.get_book(r.book) if r.book != "" else {}
	chips.add_child(UI.chip(b.title.left(28) if not b.is_empty() else ("All books" if r.book == "" else "Removed book")))
	if TextRules.validate(r) != "":
		chips.add_child(UI.chip("invalid pattern", UiTheme.BAD))
	info.add_child(chips)
	row.add_child(info)
	var tools := UI.hbox(2)
	tools.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var up := UI.icon_button("arrow_up", "Move up", func(): TextRules.move_rule(r.id, -1))
	up.disabled = index == 0
	tools.add_child(up)
	var down := UI.icon_button("arrow_down", "Move down", func(): TextRules.move_rule(r.id, 1))
	down.disabled = index == TextRules.rules.size() - 1
	tools.add_child(down)
	tools.add_child(UI.icon_button("pencil", "Edit", func(): RuleEditor.open(page.main, r)))
	tools.add_child(UI.icon_button("trash", "Delete", func(): TextRules.remove_rule(r.id)))
	if page.compact:
		tools.alignment = BoxContainer.ALIGNMENT_END
		info.add_child(tools)
	else:
		row.add_child(tools)
	var p := UI.panel("Row", row)
	return p


static func _show_replacement(rep: String) -> String:
	if rep == "":
		return "(remove)"
	if rep.strip_edges() == "":
		return "(space)"
	return rep
