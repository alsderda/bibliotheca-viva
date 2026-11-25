class_name SettingsSites
extends SettingsSection
## The Sites tab of Settings: per-site rules for how each site is handled.


func build() -> void:
	_section("Downloads", [
		_row("Reuse unchanged pages", "When a page was downloaded before, ask the site whether it changed and reuse the saved copy if it didn't. Saves the site work on update checks. Turn this off if a site keeps showing an old chapter list.", _toggle("http_revalidate")),
		_row("Keep site waits after a restart", "When a site asks the app to wait before asking again, keep waiting after the app is restarted. To clear a wait, turn this off and restart the app.", _toggle("http_keep_waits")),
	])
	var intro := UI.vbox(10)
	intro.add_child(UI.label("Site rules", "H3"))
	intro.add_child(UI.label("Tell the Web tab where the chapter text, the parts to skip, the next and previous links and the chapter title are on a site, as CSS selectors. Without a rule, the app finds the text by itself. A rule wins over what a site's plugin finds. In the Web tab, the globe button next to the address makes a rule for the site you have open.", "Muted", true))
	var add := UI.button("New site rule", "plus", "PrimaryButton", func(): SiteRuleEditor.open(page.main, {}))
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	intro.add_child(add)
	_content.add_child(UI.panel("Card", intro))

	var rules := SiteRules.all()
	if rules.is_empty():
		_content.add_child(UI.margin(UI.label("No site rules yet.", "Muted"), 6, 10, 0, 0))
		return
	var list := UI.vbox(4)
	for r in rules:
		list.add_child(_site_row(r))
	_content.add_child(UI.panel("Card", list))


func _site_row(r: Dictionary) -> Control:
	var row := UI.hbox(12)
	var info := UI.vbox(3)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(UI.label(r.host, "H3"))
	var chips := _chip_row()
	for f in SiteRules.FIELDS:
		if r.get(f, "") != "":
			chips.add_child(UI.chip(SiteRuleEditor.LABELS[f][0]))
	info.add_child(chips)
	row.add_child(info)
	var tools := UI.hbox(2)
	tools.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tools.add_child(UI.icon_button("pencil", "Edit", func(): SiteRuleEditor.open(page.main, r)))
	tools.add_child(UI.icon_button("trash", "Delete", func(): SiteRules.remove(r.id)))
	row.add_child(tools)
	return UI.panel("Row", row)
