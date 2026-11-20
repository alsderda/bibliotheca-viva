class_name SafeFile
## Saves files so a crash or a full disk part way through leaves the old file intact.


## Writes `text` to `path` through a temporary file next to it. -> true if the new text is in place.
static func write_text(path: String, text: String) -> bool:
	return write_bytes(path, text.to_utf8_buffer())


## Same as write_text, for raw bytes.
static func write_bytes(path: String, bytes: PackedByteArray) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("SafeFile: can't write %s (%s)" % [path, error_string(FileAccess.get_open_error())])
		return false
	f.store_buffer(bytes)
	var err := f.get_error()
	f.close()
	if err != OK:
		push_error("SafeFile: writing %s failed (%s)" % [path, error_string(err)])
		DirAccess.remove_absolute(tmp)
		return false
	if DirAccess.rename_absolute(tmp, path) == OK:
		return true
	# Some systems won't rename over an existing file.
	DirAccess.remove_absolute(path)
	if DirAccess.rename_absolute(tmp, path) == OK:
		return true
	push_error("SafeFile: can't replace %s" % path)
	return false
