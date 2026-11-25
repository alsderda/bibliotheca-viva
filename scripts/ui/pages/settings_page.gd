class_name SettingsPage
extends Page
## Reading, voice (TTS), text rule, tag alias, plugin, site rule and sync settings.

const TAGS_TAB := 3
const PLUGINS_TAB := 4
const SITES_TAB := 5
const SYNC_TAB := 6

var _content: VBoxContainer
var _margin: MarginContainer
var _reading_tab: SettingsReading
var _voice_tab: SettingsVoice
var _rules_tab: SettingsRules
var _tags_tab: SettingsTags
var _plugins_tab: SettingsPlugins
var _sites_tab: SettingsSites
var _sync_tab: SettingsSync
var _about_tab: SettingsAbout


func _ready() -> void:
	_content = UI.vbox(14)
	_margin = UI.margin(_content, 32, 24, 32, 40)
	_reading_tab = SettingsReading.new(self, _content)
	_voice_tab = SettingsVoice.new(self, _content)
	_rules_tab = SettingsRules.new(self, _content)
	_tags_tab = SettingsTags.new(self, _content)
	_plugins_tab = SettingsPlugins.new(self, _content)
	_sites_tab = SettingsSites.new(self, _content)
	_sync_tab = SettingsSync.new(self, _content)
	_about_tab = SettingsAbout.new(self, _content)
	var s := UI.scroll(_margin)
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(s)
	TextRules.changed.connect(func(): if visible and tab == 2: rebuild_keep_scroll())
	Sync.status_changed.connect(_sync_tab.refresh_sync_status)
	Speech.voices_changed.connect(func(): if visible and tab == 1: rebuild_keep_scroll())
	Plugins.changed.connect(func(): if visible and tab == PLUGINS_TAB: rebuild_keep_scroll())
	Settings.changed.connect(func(k): if k == "site_rules" and visible and tab == SITES_TAB: rebuild_keep_scroll())
	Settings.changed.connect(func(k): if k == "tag_aliases" and visible and tab == TAGS_TAB: rebuild_keep_scroll())


func rebuild_keep_scroll() -> void:
	var sc: ScrollContainer = get_child(0)
	var v := sc.scroll_vertical
	_rebuild()
	await get_tree().process_frame
	sc.scroll_vertical = v


func page_title() -> String:
	return "Settings"


func tabs() -> PackedStringArray:
	return ["Reading", "Voice", "Text rules", "Tags", "Plugins", "Sites", "Sync", "About"]


func on_shown() -> void:
	_rebuild()


func set_compact(v: bool) -> void:
	super(v)
	if _margin:
		for side in ["left", "right"]:
			_margin.add_theme_constant_override("margin_" + side, 12 if v else 32)
		_margin.add_theme_constant_override("margin_top", 16 if v else 24)
		if visible:
			rebuild_keep_scroll()


func _on_tab(_i: int) -> void:
	_rebuild()
	if get_child_count() > 0:
		(get_child(0) as ScrollContainer).scroll_vertical = 0


func _rebuild() -> void:
	if _content == null:
		return
	UI.clear(_content)
	match tab:
		0: _reading_tab.build()
		1: _voice_tab.build()
		2: _rules_tab.build()
		3: _tags_tab.build()
		4: _plugins_tab.build()
		5: _sites_tab.build()
		6: _sync_tab.build()
		7: _about_tab.build()


## Label + slider row bound to a setting (also used by the reader's quick panel).
static func slider_row(label: String, key: String, lo: float, hi: float, step: float, fmt: String, width := 160) -> Control:
	var row := UI.hbox(10)
	var l := UI.label(label, "Muted")
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(Settings.get_value(key))
	s.custom_minimum_size = Vector2(width, 24)
	s.focus_mode = Control.FOCUS_NONE
	var v := UI.label(fmt % s.value, "Small")
	v.custom_minimum_size.x = 58
	s.value_changed.connect(func(x): v.text = fmt % x; Settings.set_value(key, x))
	row.add_child(s)
	row.add_child(v)
	return row


static func segmented_row(key: String, options: Array) -> Control:
	var row := UI.hbox(6)
	var group := ButtonGroup.new()
	for o in options:
		var b := UI.button(o[1], "", "ChipButton")
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = Settings.get_value(key) == o[0]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): Settings.set_value(key, o[0]))
		row.add_child(b)
	return row
