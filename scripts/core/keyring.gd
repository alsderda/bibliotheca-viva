class_name Keyring
## Keeps a secret (the sync password) in the system's own credential store:
##   macOS     the login Keychain, through /usr/bin/security
##   Windows   DPAPI, which encrypts with a key tied to the Windows account
##   Android   the Android Keystore (an AES key held in hardware where the phone has it)
##   Linux     the Secret Service (GNOME Keyring, KWallet, ...), through secret-tool
## On Windows and Android the system only holds the key, so the encrypted secret is
## kept in the file `blob` (given by the caller); elsewhere `blob` is unused.
##
## Every call blocks (a helper program may take a second to start), so call them
## from a thread. The secret never appears on a command line: the helpers read it
## from their input. It's stored hex-encoded, so no character in it needs quoting.

const SERVICE := "bibliotheca-viva"
const ANDROID_PLUGIN := "BibliothecaVivaKeystore"
const TIMEOUT_MSEC := 15000
const _PS_PREFIX := "OK:"


## The store's name for the settings page, or "" when this system has none.
static func backend_name() -> String:
	match OS.get_name():
		"macOS": return "the macOS Keychain"
		"Windows": return "Windows' protected storage (DPAPI)"
		"Android": return "the Android Keystore"
		"Linux", "FreeBSD": return "the system keyring (Secret Service)"
	return ""


## -> true when the secret is saved.
static func store(id: String, secret: String, blob: String) -> bool:
	var hex := secret.to_utf8_buffer().hex_encode()
	match OS.get_name():
		"macOS":
			var cmd := "add-generic-password -U -s %s -a %s -l %s -w %s\n" % [SERVICE, id, SERVICE, hex]
			return _run_with_input("/usr/bin/security", ["-i"], cmd) == 0
		"Linux", "FreeBSD":
			var args := ["store", "--label=Bibliotheca-viva (%s)" % id, "service", SERVICE, "account", id]
			return _run_with_input("secret-tool", args, hex) == 0
		"Windows":
			return _write_blob(blob, _dpapi("protect", Marshalls.raw_to_base64(hex.to_utf8_buffer())))
		"Android":
			var ks := _android()
			return ks != null and _write_blob(blob, str(ks.seal(hex)))
	return false


## -> the secret, or null when it isn't there or the store can't be reached.
static func fetch(id: String, blob: String) -> Variant:
	var hex := ""
	match OS.get_name():
		"macOS":
			hex = _output("/usr/bin/security", ["find-generic-password", "-s", SERVICE, "-a", id, "-w"])
		"Linux", "FreeBSD":
			hex = _output("secret-tool", ["lookup", "service", SERVICE, "account", id])
		"Windows":
			var sealed := _read_blob(blob)
			var plain := _dpapi("unprotect", sealed) if sealed != "" else ""
			if plain != "":
				hex = Marshalls.base64_to_utf8(plain)
		"Android":
			var ks := _android()
			var sealed := _read_blob(blob)
			if ks != null and sealed != "":
				hex = str(ks.open(sealed))
	hex = hex.strip_edges()
	if hex == "" or hex.length() % 2 != 0 or not hex.is_valid_hex_number():
		return null
	return hex.hex_decode().get_string_from_utf8()


static func erase(id: String, blob: String) -> void:
	match OS.get_name():
		"macOS":
			_output("/usr/bin/security", ["delete-generic-password", "-s", SERVICE, "-a", id])
		"Linux", "FreeBSD":
			_output("secret-tool", ["clear", "service", SERVICE, "account", id])
	if blob != "" and FileAccess.file_exists(blob):
		DirAccess.remove_absolute(blob)


# --- helpers -----------------------------------------------------------------

static func _android() -> Object:
	return Engine.get_singleton(ANDROID_PLUGIN) if Engine.has_singleton(ANDROID_PLUGIN) else null


static func _write_blob(path: String, data: String) -> bool:
	if data == "":
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(data)
	return true


static func _read_blob(path: String) -> String:
	return FileAccess.get_file_as_string(path).strip_edges() if FileAccess.file_exists(path) else ""


## Stdout of a short command, or "" when it fails.
static func _output(path: String, args: PackedStringArray) -> String:
	var out := []
	return str(out[0]) if OS.execute(path, args, out) == 0 and not out.is_empty() else ""


## Runs a command with `input` as its whole standard input. -> its exit code, or -1.
static func _run_with_input(path: String, args: PackedStringArray, input: String) -> int:
	var p := OS.execute_with_pipe(path, args)
	if p.is_empty():
		return -1
	var io: FileAccess = p.stdio
	io.store_string(input)
	io.flush()
	io.close()  # end of input; these helpers print nothing on success
	return _wait(p.pid)


static func _wait(pid: int) -> int:
	var until := Time.get_ticks_msec() + TIMEOUT_MSEC
	while OS.is_process_running(pid):
		if Time.get_ticks_msec() > until:
			OS.kill(pid)
			return -1
		OS.delay_msec(20)
	return OS.get_process_exit_code(pid)


## Encrypts or decrypts base64 data with DPAPI for the current Windows user.
## -> the result as base64, or "" when it fails.
static func _dpapi(mode: String, data_b64: String) -> String:
	var script := "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Security; " \
		+ "$m=[Console]::In.ReadLine(); $d=[Convert]::FromBase64String([Console]::In.ReadLine()); " \
		+ "$e=[Text.Encoding]::UTF8.GetBytes('%s'); $s=[Security.Cryptography.DataProtectionScope]::CurrentUser; " % SERVICE \
		+ "if ($m -eq 'protect') { $r=[Security.Cryptography.ProtectedData]::Protect($d,$e,$s) } " \
		+ "else { $r=[Security.Cryptography.ProtectedData]::Unprotect($d,$e,$s) }; " \
		+ "[Console]::Out.WriteLine('%s' + [Convert]::ToBase64String($r))" % _PS_PREFIX
	# -EncodedCommand takes UTF-16LE base64, so the script needs no quoting on the command line.
	var encoded := Marshalls.raw_to_base64(script.to_utf16_buffer())
	var p := OS.execute_with_pipe("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded])
	if p.is_empty():
		return ""
	var io: FileAccess = p.stdio
	io.store_line(mode)
	io.store_line(data_b64)
	io.flush()
	var result := ""
	var until := Time.get_ticks_msec() + TIMEOUT_MSEC
	while io.is_open() and Time.get_ticks_msec() < until:
		var line := io.get_line().strip_edges()
		if line.begins_with(_PS_PREFIX):
			result = line.substr(_PS_PREFIX.length())
			break
		if io.get_error() != OK and line == "":
			break
	io.close()
	if OS.is_process_running(p.pid):
		_wait(p.pid)
	return result
