class_name SettingsVoice
extends SettingsSection
## The Voice tab of Settings: the read-aloud voice, a sample to try it, and the sleep timer.


func build() -> void:
	if not Speech.is_supported():
		_section("Text-to-speech", [UI.label("This platform doesn't expose system voices to Godot. On Linux install speech-dispatcher; on the web use a browser with the Web Speech API.", "Muted", true)])
		return
	var pick := OptionButton.new()
	pick.custom_minimum_size.x = 260 if not page.compact else 0
	pick.focus_mode = Control.FOCUS_NONE
	pick.fit_to_longest_item = false
	pick.clip_text = page.compact
	pick.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var current := Speech.voice_id()
	var voices := Speech.voices()
	voices.sort_custom(func(a, b): return (a.language.begins_with("en") and not b.language.begins_with("en")) or (a.language.begins_with("en") == b.language.begins_with("en") and a.name < b.name))
	for i in voices.size():
		pick.add_item("%s  (%s)" % [voices[i].name, voices[i].language])
		pick.set_item_metadata(i, voices[i].id)
		if voices[i].id == current:
			pick.select(i)
	pick.item_selected.connect(func(i): Settings.set_value("tts_voice", pick.get_item_metadata(i)))
	var voice_row := _row("Voice", "%d system voices available. Install more in your OS settings." % voices.size(), pick)
	if Speech.uses_system_voice():
		voice_row = _row("Voice", "Uses the engine and voice chosen in Android's text-to-speech settings. After switching engines, restart the app.",
			UI.button("System settings", "settings", "", func(): Speech.open_system_settings()))
	var sample := _line_edit(Settings.get_value("tts_preview_text"), 260)
	sample.size_flags_horizontal = Control.SIZE_EXPAND_FILL if page.compact else Control.SIZE_FILL
	sample.text_changed.connect(func(t): Settings.set_value("tts_preview_text", t))
	var test := UI.button("Test", "volume", "", func(): Speech.preview(TextRules.apply_tts(sample.text)))
	var test_row := UI.hbox(8, [sample, test])
	_section("Voice", [
		voice_row,
		_row("Speed", "1.00x is the voice's normal pace.", _slider("tts_rate", 0.5, 3.0, 0.05, "%.2fx")),
		_row("Pitch", "", _slider("tts_pitch", 0.5, 1.5, 0.05, "%.2f")),
		_row("Volume", "", _slider("tts_volume", 0, 100, 1, "%d%%")),
		_row("Test sentence", "Speech rules are applied to the test too.", test_row),
	])
	_section("Pauses and pacing", [
		_row("Speak in", "Sentences gives finer pauses and skipping; paragraphs sound more fluid on some voices.", _segmented("tts_mode", [["paragraph", "Paragraphs"], ["sentence", "Sentences"]])),
		_row("Pause between sentences", "Only in Sentences mode.", _slider("tts_pause_sentence", 0, 2000, 10, "%d ms")),
		_row("Pause between paragraphs", "", _slider("tts_pause_paragraph", 0, 3000, 10, "%d ms")),
		_row("Pause after headings", "After chapter titles and section headings.", _slider("tts_pause_heading", 0, 4000, 10, "%d ms")),
		_row("Pause before next chapter", "", _slider("tts_pause_chapter", 0, 10000, 250, "%d ms")),
		_row("Split long paragraphs", "Paragraphs longer than this are read sentence by sentence, which keeps some voices from stalling.", _slider("tts_max_chars", 200, 5000, 100, "%d chars")),
	])
	var rules_n := TextRules.rules.filter(func(r): return r.enabled and r.scope != "display").size()
	var rules_btn := UI.button("Edit speech rules (%d)" % rules_n, "replace", "", func(): page.select_tab(2); page.header_changed.emit())
	_section("What gets read", [
		_row("Read chapter titles and headings", "", _toggle("tts_read_headings")),
		_row("Skip lines without words", "Scene breaks like “* * *” or “~~~”.", _toggle("tts_skip_symbols")),
		_row("Pronunciation and skipping", "Use rules to fix names or keep things like [system notices] from being read.", rules_btn),
	])
	_section("While reading aloud", [
		_row("Highlight", "How the paragraph being read is marked.", _segmented("tts_highlight", [["background", "Background"], ["underline", "Underline"], ["color", "Colour"], ["none", "None"]])),
		_row("Follow along", "Scroll the text to the paragraph being read.", _toggle("tts_follow")),
		_row("Continue to next chapter", "Keep reading aloud when a chapter ends.", _toggle("tts_auto_advance")),
		_row("Sleep timer", "Stop reading after a while. Also on the player's moon button.", _sleep_picker()),
	])


func _sleep_picker() -> Control:
	var row := _chip_row()
	var group := ButtonGroup.new()
	for m in [0, 15, 30, 60, -1]:
		var b := UI.button("Off" if m == 0 else ("Chapter end" if m == -1 else "%d min" % m), "", "ChipButton")
		if page.compact:
			b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = Speech.sleep_minutes == m
		b.pressed.connect(func(): Speech.set_sleep(m))
		row.add_child(b)
	return row
