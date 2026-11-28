class_name SyncSecret
extends RefCounted
## The sync password: read from and saved to the system's keyring, or to the
## fallback file where there is none. Sync keeps the state and the password
## itself; this helper calls back into it for those.

# Untyped on purpose: the owner is the Sync autoload, which has no class_name, and
# its private methods would fail a typed check at compile time.
var _owner
var _secret_thread: Thread   # reads or saves the password (see Keyring)


func _init(owner_node: Node) -> void:
	_owner = owner_node


## Fallback for systems without a keyring: encrypted with a key made from this
## device's id. That keeps it out of plain view, but isn't strong protection.
func secret_path() -> String:
	return Settings.data_dir() + "/sync_secret.dat"


## Where Keyring keeps the encrypted password on Windows and Android.
func _sealed_path() -> String:
	return ProjectSettings.globalize_path(Settings.data_dir() + "/sync_secret.sealed")


func _keyring_id() -> String:
	return "sync-" + Settings.profile


# --- the password ------------------------------------------------------------
# It's kept in the system's keyring (see Keyring) and, where there is none, in the
# fallback file. Sync's state (password_in) says which: "keyring", "file" or "" (none).
# Reading and saving run in a thread, since the keyring helpers can be slow to start.

func load_password() -> void:
	if not _owner.is_configured() and not FileAccess.file_exists(secret_path()):
		_owner._password_ready = true
		return
	var found: Dictionary = await _in_secret_thread(read_password.bind(_keyring_id(), _sealed_path(), secret_path(), _secret_key()))
	if _owner._password_ready:  # a new password was entered meanwhile
		return
	_owner._password = found.password
	_owner._password_ready = true
	_owner._state.password_in = found.where
	_owner._save_state()
	_owner.status_changed.emit()


func save_password() -> void:
	var where: String = await _in_secret_thread(write_password.bind(_owner._password, _keyring_id(), _sealed_path(), secret_path(), _secret_key()))
	_owner._state.password_in = where
	_owner._save_state()
	_owner.status_changed.emit()


func wait_for_password() -> void:
	while not _owner._password_ready:
		await _owner.get_tree().process_frame


## Runs `job` in a thread, one at a time, and returns its result.
func _in_secret_thread(job: Callable) -> Variant:
	while _secret_thread != null:
		await _owner.get_tree().process_frame
	_secret_thread = Thread.new()
	_secret_thread.start(job)
	while _secret_thread.is_alive():
		await _owner.get_tree().process_frame
	var result: Variant = _secret_thread.wait_to_finish()
	_secret_thread = null
	return result


func wait_for_thread() -> void:
	if _secret_thread != null:
		var t := Time.get_ticks_msec()
		_secret_thread.wait_to_finish()
		AppLog.info("close", "password thread finished in %d ms" % AppLog.since(t))


## In a thread. Reads the keyring first, then the fallback file, and moves a
## password found in the file into the keyring. -> {password, where}
static func read_password(id: String, sealed: String, file: String, key: String) -> Dictionary:
	var secret: Variant = Keyring.fetch(id, sealed)
	if secret is String and secret != "":
		return {"password": secret, "where": "keyring"}
	var f := FileAccess.open_encrypted_with_pass(file, FileAccess.READ, key)
	if f == null:
		return {"password": "", "where": ""}
	var password := f.get_as_text()
	f.close()
	if password != "" and Keyring.store(id, password, sealed):
		DirAccess.remove_absolute(file)
		return {"password": password, "where": "keyring"}
	return {"password": password, "where": "file" if password != "" else ""}


## In a thread. -> where it was saved: "keyring" or "file".
static func write_password(password: String, id: String, sealed: String, file: String, key: String) -> String:
	if Keyring.store(id, password, sealed):
		if FileAccess.file_exists(file):
			DirAccess.remove_absolute(file)
		return "keyring"
	Keyring.erase(id, sealed)  # don't leave an older password behind
	# Through a temp file, so a crash keeps the old password.
	var tmp := file + ".tmp"
	var f := FileAccess.open_encrypted_with_pass(tmp, FileAccess.WRITE, key)
	if f:
		f.store_string(password)
		f.close()
		if DirAccess.rename_absolute(tmp, file) != OK:
			DirAccess.remove_absolute(file)
			DirAccess.rename_absolute(tmp, file)
	return "file"


static func _secret_key() -> String:
	return "serial-reader-sync:" + OS.get_unique_id()
