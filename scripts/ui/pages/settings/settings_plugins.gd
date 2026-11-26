class_name SettingsPlugins
extends SettingsSection
## The Plugins tab of Settings: installed plugins and the plugin repositories that can be installed from.


var _repo_lists := {}   # repo link -> what it lists (cached while the app runs)
var _folder_dialog: FileDialog


func build() -> void:
	var warn := UI.hbox(10, [UI.icon("shield", UiTheme.WARN, 18)])
	var wl := UI.label("Plugins add sites to the app: searching them, adding books by link and downloading chapters. A plugin runs inside the app with the same access the app has (your library, files and the network), so only install plugins from people you trust. With Sync on, installed plugins are copied to your other devices too.", "Muted", true)
	wl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	warn.add_child(wl)
	_content.add_child(UI.panel("Banner", warn))

	if Plugins.entries.is_empty():
		_section("Installed plugins", [UI.label("None yet. Install one from a link or a plugin repository below.", "Muted", true)])
	for e in Plugins.entries:
		_plugin_card(e)

	var link := _line_edit("", 360)
	link.placeholder_text = "Link to a plugin (its plugin.json, folder or GitHub page)"
	var install := func():
		var url := link.text.strip_edges()
		if url != "":
			_confirm_install("this plugin", url, func():
				page.main.toast("Installing…")
				var r: Dictionary = await Plugins.install_from_url(url)
				page.main.toast(r.error if r.has("error") else "Installed %s %s" % [r.name, r.version], "error" if r.has("error") else "ok"))
	link.text_submitted.connect(func(_t): install.call())
	var rows: Array = [_row("From a link", "Works on every device.", UI.hbox(8, [link, UI.button("Install", "download", "PrimaryButton", install)]))]
	if OS.has_feature("pc"):
		rows.append(_row("From a folder", "A plugin folder on this computer (one with a plugin.json).", UI.button("Choose folder…", "import", "", _choose_folder)))
	_section("Install a plugin", rows)

	var repo_rows: Array = [UI.label("A plugin repository lists several plugins. Add it once to see what it has and get updates.", "Muted", true)]
	for url in Plugins.repos():
		repo_rows.append(_repo_box(url))
	var repo := _line_edit("", 360)
	repo.placeholder_text = "Link to a repository (its index.json, folder or GitHub page)"
	var add_repo := func():
		var url := repo.text.strip_edges()
		if url == "":
			return
		var r: Dictionary = await Plugins.add_repo(url)
		if r.has("error"):
			page.main.toast(r.error, "error")
		else:
			_repo_lists[url] = r
			page.rebuild_keep_scroll()
	repo.text_submitted.connect(func(_t): add_repo.call())
	repo_rows.append(UI.hbox(8, [repo, UI.button("Add", "plus", "", add_repo)]))
	_section("Plugin repositories", repo_rows)


func _plugin_card(e: Dictionary) -> void:
	var head := UI.hbox(10, [UI.icon("globe", UiTheme.ACCENT, 20)])
	var tv := UI.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.add_child(UI.label(e.name, "H3"))
	var where := "installed" if e.origin == "installed" else "from the plugins folder"
	tv.add_child(UI.label("Version %s · %s%s" % [e.version, where, (" · by " + str(e.manifest.author)) if e.manifest.get("author", "") != "" else ""], "Small"))
	head.add_child(tv)
	if e.origin == "installed":
		head.add_child(UI.icon_button("trash", "Remove", func(): ConfirmDialog.open(page.main, {
			"title": "Remove %s?" % e.name, "icon": "trash", "confirm": "Remove", "confirm_icon": "trash", "danger": true,
			"text": "Books from it stay in your library, but can't get new chapters until it's installed again.",
		}, func(): Plugins.remove(e.id))))
	var on := CheckButton.new()
	on.button_pressed = e.enabled
	on.tooltip_text = "On / off"
	on.toggled.connect(func(v): Plugins.set_enabled(e.id, v))
	head.add_child(on)
	var rows: Array = [head]
	var desc: String = str(e.manifest.get("description", ""))
	if desc != "":
		rows.append(UI.label(desc, "Muted", true))
	if e.error != "":
		var err := UI.label(e.error, "Small", true)
		err.add_theme_color_override("font_color", UiTheme.WARN)
		rows.append(err)
	var p: SourcePlugin = e.plugin
	if p:
		for r in p.settings_rows():
			var control: Control = r[2]
			if control is LineEdit and page.compact:
				control.custom_minimum_size.x = 0
			rows.append(_row(r[0], r[1], control))
	var card := UI.panel("Card")
	card.add_child(UI.vbox(12, rows))
	_content.add_child(card)


## A repository's plugins, with Install / Update buttons.
func _repo_box(url: String) -> Control:
	var col := UI.vbox(6)
	var head := UI.hbox(8)
	var title := UI.label(url, "", true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(UI.icon_button("refresh", "Check again", func(): _repo_lists.erase(url); page.rebuild_keep_scroll()))
	head.add_child(UI.icon_button("x", "Remove this repository", func(): Plugins.remove_repo(url); _repo_lists.erase(url); page.rebuild_keep_scroll()))
	col.add_child(head)
	var list := UI.vbox(6)
	col.add_child(list)
	_fill_repo(url, title, list)
	return UI.panel("Row", col)


func _fill_repo(url: String, title: Label, list: VBoxContainer) -> void:
	if not _repo_lists.has(url):
		list.add_child(UI.label("Loading…", "Small"))
		_repo_lists[url] = await Plugins.resolve(url)
		if not is_instance_valid(list):
			return
		UI.clear(list)
	var r: Dictionary = _repo_lists[url]
	if r.has("error"):
		var err := UI.label(r.error, "Small", true)
		err.add_theme_color_override("font_color", UiTheme.WARN)
		list.add_child(err)
		return
	title.text = r.get("name", url)
	title.tooltip_text = url
	for item in r.get("plugins", []):
		var row := UI.hbox(10)
		var v := UI.vbox(0)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(UI.label("%s  ·  %s" % [item.name, item.version], ""))
		if item.description != "":
			v.add_child(UI.label(item.description, "Small", true))
		row.add_child(v)
		var have := Plugins.get_entry(item.id)
		var btn: Button
		if item.error != "":
			btn = UI.button("Can't run here", "", "", Callable())
			btn.tooltip_text = item.error
			btn.disabled = true
		elif have.is_empty() or (have.origin == "installed" and Plugins.compare_versions(item.version, have.version) > 0):
			btn = UI.button("Install" if have.is_empty() else "Update", "download", "PrimaryButton" if have.is_empty() else "", Callable())
			btn.pressed.connect(func(): _confirm_install(item.name, item.manifest_url, func():
				btn.disabled = true
				var res: Dictionary = await Plugins.install_listed(item)
				page.main.toast(res.error if res.has("error") else "Installed %s %s" % [res.name, res.version], "error" if res.has("error") else "ok")))
		else:
			btn = UI.button("Installed", "check", "", Callable())
			btn.disabled = true
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(btn)
		list.add_child(row)


func _confirm_install(name: String, detail: String, then: Callable) -> void:
	ConfirmDialog.open(page.main, {
		"title": "Install %s?" % name, "detail": detail, "icon": "shield", "confirm": "Install", "confirm_icon": "download",
		"text": "Plugins run inside the app with the same access the app has. Only install plugins from people you trust.",
	}, then)


func _choose_folder() -> void:
	if _folder_dialog == null:
		_folder_dialog = FileDialog.new()
		_folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_folder_dialog.use_native_dialog = true
		_folder_dialog.dir_selected.connect(func(path): _confirm_install("this plugin", path, func():
			var r := Plugins.install_from_folder(path)
			page.main.toast(r.error if r.has("error") else "Installed %s %s" % [r.name, r.version], "error" if r.has("error") else "ok")))
		page.add_child(_folder_dialog)
	_folder_dialog.popup_centered_ratio(0.6)
