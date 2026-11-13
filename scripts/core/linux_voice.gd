class_name LinuxVoice
extends Node
## Linux speech through speech-dispatcher's spd-say, as plain text.
##
## Godot's own Linux TTS sends every utterance in SSML mode with a <mark name="N"/>
## after each word, but without a <speak> root and without escaping & or <. Engines
## that only treat a message as SSML when it starts with "<" (RHVoice) then read the
## tags out loud: "Hello mark name 5 world mark name 11". So each utterance is spoken
## here by one `spd-say --wait` process instead; it exits when the speech ends.
##
## spd-say can't pause, so pause() stops the utterance and resume() starts it again.

signal ended(id: int)
signal failed  # spd-say is unusable; the caller should fall back to DisplayServer TTS

const APP_NAME := "bibliotheca-viva"
## speech-dispatcher applies a cancel a moment after confirming it, and a message that
## arrives in between is dropped too (about 20 ms in tests, 50 ms was always enough).
const AFTER_CANCEL_MS := 120

var _pid := -1
var _id := -1
var _args := PackedStringArray()  # of the current utterance, to start it again on resume()
var _paused := false
var _started_at := 0
var _cancelled_at := -AFTER_CANCEL_MS
var _launch_pending := false


static func available() -> bool:
	if OS.get_name() not in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		return false
	if not DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH):
		return false
	return OS.execute("sh", ["-c", "command -v spd-say"]) == 0


func _ready() -> void:
	set_process(false)


func _exit_tree() -> void:
	stop()


func speak(text: String, voice: String, volume: int, rate: float, pitch: float, id: int) -> void:
	stop()
	# The same mappings Godot uses for speech-dispatcher (platform/linuxbsd/tts_linux.cpp).
	var spd_rate := 0.0
	if rate > 1.0:
		spd_rate = log(minf(rate, 2.5)) / log(2.5) * 100.0
	elif rate < 1.0:
		spd_rate = log(maxf(rate, 0.5)) / log(0.5) * -100.0
	_args = PackedStringArray(["--wait", "--application-name", APP_NAME,
		"--rate", str(roundi(spd_rate)),
		"--pitch", str(clampi(roundi((pitch - 1.0) * 100.0), -100, 100)),
		"--volume", str(clampi(volume * 2 - 100, -100, 100))])
	if voice != "":
		_args.append_array(["--synthesis-voice", voice])
	_args.append_array(["--", text])  # "--" so text starting with "-" isn't taken as an option
	_id = id
	_launch()


func stop() -> void:
	_id = -1
	_paused = false
	_halt()


func pause() -> void:
	if _id == -1 or _paused:
		return
	_paused = true
	_halt()


func resume() -> void:
	if not _paused:
		return
	_paused = false
	if _id != -1:
		_launch()


# --- internals ---------------------------------------------------------------

func _launch() -> void:
	if Time.get_ticks_msec() - _cancelled_at < AFTER_CANCEL_MS:
		_launch_pending = true  # _process() starts it once the cancel has taken effect
		set_process(true)
		return
	_launch_pending = false
	_pid = OS.create_process("spd-say", _args)
	_started_at = Time.get_ticks_msec()
	if _pid <= 0:
		_pid = -1
		_fail("could not start spd-say")
		return
	set_process(true)


## Stop the running utterance. Killing spd-say only drops its connection; the message
## it already handed to speech-dispatcher keeps playing, so it is cancelled as well.
## This waits for the cancel so it can't hit an utterance started right after.
func _halt() -> void:
	set_process(false)
	_launch_pending = false
	if _pid <= 0:
		return
	var was_running := OS.is_process_running(_pid)
	OS.kill(_pid)
	_pid = -1
	if was_running:
		OS.execute("spd-say", ["--application-name", APP_NAME, "--cancel"])
		_cancelled_at = Time.get_ticks_msec()


func _process(_delta: float) -> void:
	if _launch_pending:
		_launch()
		return
	if _pid <= 0 or OS.is_process_running(_pid):
		return
	var code := OS.get_process_exit_code(_pid)
	_pid = -1
	set_process(false)
	if code != 0:
		_fail("spd-say exited with code %d after %d ms" % [code, Time.get_ticks_msec() - _started_at])
		return
	var id := _id
	_id = -1
	ended.emit(id)


func _fail(why: String) -> void:
	push_warning("LinuxVoice disabled: " + why)
	AppLog.info("tts", "LinuxVoice disabled: " + why)
	failed.emit()
