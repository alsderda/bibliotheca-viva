class_name SyncPlugins
extends RefCounted
## The plugin part of the library sync: installs, updates and removes plugins as
## other devices did, and uploads the plugins this device has that the server
## doesn't. Sync keeps the connection, the progress line and the state; this
## helper calls back into it for those.

# Untyped on purpose: the owner is the Sync autoload, which has no class_name, and
# its private methods would fail a typed check at compile time.
var _owner


func _init(owner_node: Node) -> void:
	_owner = owner_node


## A name from another device that is safe to put in a server or local path (a
## plugin id or version, a cover file name). Anything that could escape its
## folder is refused, and the entry is skipped.
static func safe_name(s: String) -> bool:
	if s == "" or s.begins_with(".") or s.length() > 128:
		return false
	for bad in ["/", "\\", ":", ".."]:
		if bad in s:
			return false
	for b in s.to_utf8_buffer():
		if b < 32 or b == 127:
			return false
	return true


## Install, update or remove plugins as other devices did, then upload the
## plugins this device has that the server doesn't have yet.
func sync_plugins(dav: WebDav, remote: Array) -> String:
	var newest := SyncMerge.newest_plugin_records(remote)  # id -> the most recent record of any other device
	var mine := Plugins.sync_records()
	for id in newest:
		if not (id is String and safe_name(id)):
			print("Sync: plugin %s: skipped: unsafe id" % str(id))
			continue
		var r: Dictionary = newest[id]
		var m: Dictionary = mine.get(id, {})
		if SyncMerge.num(r.get("t", 0)) <= SyncMerge.num(m.get("t", 0)):
			continue
		if r.get("removed", false):
			if Plugins.is_installed(id):
				Plugins.remove(id, SyncMerge.num(r.get("t", 0)))
			continue
		if not Plugins.get_entry(id).is_empty() and not m.get("removed", false) and Plugins.compare_versions(str(r.get("v", "")), str(m.get("v", ""))) <= 0:
			continue  # already have this version (or a newer one)
		if not safe_name(str(r.get("v", ""))):
			print("Sync: plugin %s: skipped: unsafe version" % id)
			continue
		_owner._set_progress("Installing plugin %s…" % id)
		await _download_plugin(dav, id, str(r.get("v", "")), SyncMerge.num(r.get("t", 0)))

	var listing := await dav.list(Sync.FOLDER + "plugins/")
	if not listing.ok:
		return listing.error
	var have := Plugins.sync_records()
	for id in have:
		var r: Dictionary = have[id]
		if r.get("removed", false):
			continue
		if not (id is String and safe_name(id) and safe_name(str(r.get("v", "")))):
			print("Sync: plugin %s: skipped: unsafe id or version" % str(id))
			continue
		var files := Plugins.files_of(id)
		if files.is_empty():
			continue  # not all its files are readable here (e.g. an exported build)
		var folder := Sync.FOLDER + "plugins/%s/%s/" % [id, r.v]
		if Sync._listed(listing, id):
			var versions := await dav.list(Sync.FOLDER + "plugins/%s/" % id)
			if versions.ok and Sync._listed(versions, str(r.v)):
				# The manifest goes up last and marks the version complete, so
				# only it says the upload finished (a folder alone may hold an
				# interrupted upload, which downloaders skip as incomplete).
				var uploaded := await dav.list(folder)
				if uploaded.ok and SyncMerge.version_complete(uploaded.entries, Plugins.MANIFEST):
					continue
		_owner._set_progress("Uploading plugin %s…" % id)
		var made := {}
		for rel in files:
			if rel == Plugins.MANIFEST:
				continue
			var err := await _put_plugin_file(dav, folder, rel, files[rel], made)
			if err != "":
				return err
		var err := await _put_plugin_file(dav, folder, Plugins.MANIFEST, files[Plugins.MANIFEST], made)  # last: marks it complete
		if err != "":
			return err
	return ""


## Upload one file of a plugin, creating its folders on the way (`made` remembers them).
func _put_plugin_file(dav: WebDav, folder: String, rel: String, path: String, made: Dictionary) -> String:
	var base := Sync.FOLDER + "plugins/"
	var dirs := (folder.trim_prefix(base) + rel).split("/")
	var at := base
	for i in dirs.size() - 1:
		at += dirs[i] + "/"
		if made.has(at):
			continue
		var r := await dav.make_dir(at)
		if not r.ok and r.code != 405:  # 405: it's already there
			return r.error
		made[at] = true
	var put := await dav.put(folder + rel, FileAccess.get_file_as_bytes(path))
	return "" if put.ok else put.error


## Install a plugin version from the server. Reads its plugin.json first and
## skips a plugin that can't run here without downloading its files. Any failure
## only skips this plugin (it's tried again next time); the rest of the sync goes on.
func _download_plugin(dav: WebDav, id: String, version: String, stamp: float) -> void:
	if not safe_name(id) or not safe_name(version):
		print("Sync: plugin %s: skipped: unsafe id or version" % id)
		return
	var folder := Sync.FOLDER + "plugins/%s/%s/" % [id, version]
	var g := await dav.fetch(folder + Plugins.MANIFEST)
	if not g.ok:
		if g.code != 404:  # 404: not uploaded completely yet
			print("Sync: plugin %s: couldn't download %s (%s)" % [id, Plugins.MANIFEST, g.error])
		return
	var m: Variant = JSON.parse_string(g.body.get_string_from_utf8())
	if not (m is Dictionary):
		print("Sync: plugin %s: %s is damaged" % [id, Plugins.MANIFEST])
		return
	var why := Plugins.check_manifest(m)
	if why != "":  # e.g. a desktop-only plugin on a phone
		print("Sync: plugin %s: skipped: %s" % [id, why])
		return
	var files := {Plugins.MANIFEST: g.body}
	for rel in m.get("files", []):
		var f := await dav.fetch(folder + str(rel))
		if not f.ok:
			print("Sync: plugin %s: couldn't download %s (%s)" % [id, rel, f.error])
			return
		files[str(rel)] = f.body
	var r := Plugins.install_files(m, files, stamp)
	if r.has("error"):
		print("Sync: plugin %s: %s" % [id, r.error])
