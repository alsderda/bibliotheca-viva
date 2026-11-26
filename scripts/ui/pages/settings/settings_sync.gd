class_name SettingsSync
extends SettingsSection
## The Sync tab of Settings: syncing reading progress and library between devices.


var _sync_status: Label
var _sync_devices: VBoxContainer


func build() -> void:
	var url := _line_edit(Sync.server_url())
	url.placeholder_text = "https://example.com/dav/"
	var user := _line_edit(Sync.user_name())
	var password := _line_edit("")
	password.secret = true
	password.placeholder_text = "saved" if Sync.has_password() else ""
	var result := UI.label("", "Small", true)
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	result.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var apply := func():
		Sync.configure(url.text, user.text, password.text)
		password.text = ""
		password.placeholder_text = "saved" if Sync.has_password() else ""
		result.text = "Connecting…"
		result.add_theme_color_override("font_color", UiTheme.MUTED)
		var err: String = await Sync.test_connection()
		result.text = "Connected." if err == "" else err
		result.add_theme_color_override("font_color", UiTheme.GOOD if err == "" else UiTheme.BAD)
	var save := UI.button("Save and test", "check", "", func():
		if url.text.strip_edges().to_lower().begins_with("http://"):
			_confirm_insecure_sync(url.text.strip_edges(), apply)
		else:
			apply.call())
	save.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var on := CheckButton.new()
	on.button_pressed = Sync.is_enabled()
	on.focus_mode = Control.FOCUS_NONE
	on.toggled.connect(func(v):
		if v and not Sync.is_configured():
			on.set_pressed_no_signal(false)
			result.text = "Enter the server address first."
			result.add_theme_color_override("font_color", UiTheme.BAD)
			return
		Sync.set_enabled(v))
	var name := _line_edit(Sync.device_name())
	name.text_submitted.connect(func(t): Sync.set_device_name(t))
	name.focus_exited.connect(func(): if name.text != Sync.device_name(): Sync.set_device_name(name.text))
	_section("Sync between devices", [
		UI.label("Keeps your library, saved chapters, reading position, text rules and settings the same on all your devices, through a folder on a WebDAV server. The app creates a bibliotheca-viva folder there.", "Muted", true),
		_row("Server address", "The WebDAV address from your provider (see below).", url),
		_row("Username", "", user),
		_row("Password", "Use an app password if your provider has them. Kept in %s." % Sync.password_store_name(), password),
		UI.hbox(12, [save, result]),
		_row("Sync", "Syncs at start, a few seconds after changes, every 10 minutes, and when closing.", on),
		_row("This device", "Shown to your other devices.", name),
	])

	_sync_status = UI.label("", "")
	_sync_devices = UI.vbox(6)
	var now := UI.button("Sync now", "refresh", "", func():
		var err: String = await Sync.sync_now(true)
		page.main.toast("Synced" if err == "" else "Sync failed: " + err, "ok" if err == "" else "error"))
	_section("Status", [
		UI.hbox(12, [_sync_status, UI.spacer(), now]),
		UI.label("OTHER DEVICES", "Overline"),
		_sync_devices,
	])
	refresh_sync_status()

	_section("Where to get a WebDAV folder", [
		UI.label("Koofr (10 GB free): address https://app.koofr.net/dav/Koofr/, username is your Koofr email, and the password is an app password from Preferences → Password (your normal password won't work).", "Muted", true),
		UI.label("Nextcloud: address https://<your server>/remote.php/dav/files/<your username>/ and an app password from Settings → Security.", "Muted", true),
		UI.label("Any other WebDAV server works too. Google Drive and Dropbox don't offer WebDAV.", "Muted", true),
		UI.label("Not synced: text size and layout (each device keeps its own), the selected voice (voices differ between devices) and plugins' own settings. When the same setting or book is changed on two devices, the most recent change wins; chapters saved on any device are kept.", "Small", true),
	])


func refresh_sync_status() -> void:
	if not is_instance_valid(_sync_status):
		return
	var text := ""
	var color := UiTheme.MUTED
	if Sync.running:
		text = Sync.progress_text
	elif not Sync.is_configured():
		text = "Not set up"
	elif not Sync.is_enabled():
		text = "Off"
	elif Sync.last_error != "":
		text = "Last sync failed: " + Sync.last_error
		color = UiTheme.BAD
	else:
		text = "Last synced " + UI.relative_time(Sync.last_sync)
		color = UiTheme.GOOD
	_sync_status.text = text
	_sync_status.add_theme_color_override("font_color", color)
	_sync_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sync_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if is_instance_valid(_sync_devices):
		UI.clear(_sync_devices)
		if Sync.devices.is_empty():
			_sync_devices.add_child(UI.label("None yet. Set up sync with the same folder on your other devices.", "Small", true))
		for d in Sync.devices:
			var dev := UI.label(str(d.get("name", "Unknown device")), "", true)
			dev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var changed := UI.label("changed " + UI.relative_time(float(d.get("updated", 0))), "Small")
			changed.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			_sync_devices.add_child(UI.hbox(10, [UI.icon("server"), dev, changed]))


## Plain http:// sends the username and password unencrypted with every request,
## so the user has to type "confirm" before such an address is saved.
func _confirm_insecure_sync(address: String, then: Callable) -> void:
	ConfirmDialog.open(page.main, {
		"title": "Use an unencrypted connection?", "detail": address, "icon": "shield", "danger": true,
		"text": "This address starts with http://, not https://. Your username, password and library will be sent unencrypted, so anyone on the same network (public Wi-Fi, for example) can read them. Use https:// if your server supports it.\n\nType confirm to use this address anyway.",
		"input": "", "input_hint": "confirm", "require": "confirm", "confirm": "Use http://",
	}, func(_typed): then.call())
