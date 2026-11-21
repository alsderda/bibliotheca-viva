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
## spd-say can't pause, so pause() stops the utterance and resume() speaks its
## unheard rest: the offset reached is estimated from the speaking time and the
## measured rate, snapped back to a word start, and reported so the highlight
## can continue from the same place.
##
## RHVoice voices are rendered to a file with RHVoice-test instead, when it is
## installed, and played with an AudioStreamPlayer, like WinVoice does on Windows.
## RHVoice can't speak faster than 2x (speech-dispatcher's fastest rate is that same
## 2x), so the rest of a higher speed is made up by time-stretching the clip (WSOLA,
## keeps the pitch). The next clip is rendered while the current one plays, and
## pausing is a real pause. If rendering fails, these voices go through spd-say too.

signal ended(id: int)
signal failed  # spd-say is unusable; the caller should fall back to DisplayServer TTS
## resume() restarted the utterance at this character offset of its text.
signal resumed(id: int, offset: int)

const APP_NAME := "bibliotheca-viva"
## speech-dispatcher applies a cancel a moment after confirming it, and a message that
## arrives in between is dropped too (about 20 ms in tests, 50 ms was always enough).
const AFTER_CANCEL_MS := 120
const RH_TOOL := "RHVoice-test"
## The speeds RHVoice itself can reach; it quietly clamps anything outside.
const RH_MIN_RATE := 0.5
const RH_MAX_RATE := 2.0
## Starting guess of characters spoken per second at 1x, for the resume offset.
const EST_CPS := 14.0

var _pid := -1
var _id := -1
var _args := PackedStringArray()  # launch args of the current utterance, ending with its text
var _full := ""  # the whole utterance text, to resume from an offset on resume()
var _base := 0  # offset in _full of the text currently being spoken
var _rate_now := 1.0  # rate of the current utterance, for the resume estimate
var _resume_off := 0  # offset in _full to resume from
var _cps := EST_CPS  # measured characters per second at 1x, learned from finished utterances
var _paused := false
var _started_at := 0
var _cancelled_at := -AFTER_CANCEL_MS
var _launch_pending := false

var _rh_checked := false
var _rh_voices := {}    # names of the voices RHVoice-test can render
var _dir := ""
var _next_req := 1
var _jobs: Array = []   # running RHVoice-test processes: [{key, pid, txt, wav, extra}]
var _tasks := {}        # WorkerThreadPool task id -> true, clips being loaded and stretched
var _clips := {}        # key -> AudioStreamWAV, or null while being rendered
var _order: Array = []  # keys, oldest first, to bound the cache
var _want_key := ""     # clip to play as soon as it is rendered
var _want_id := -1
var _want: Array = []   # speak() arguments of that clip, to redo it with spd-say if rendering fails
var _playing_id := -1
var _player: AudioStreamPlayer


static func available() -> bool:
	if OS.get_name() not in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		return false
	if not DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH):
		return false
	return OS.execute("sh", ["-c", "command -v spd-say"]) == 0


func _ready() -> void:
	set_process(false)
	_player = AudioStreamPlayer.new()
	add_child(_player)
	_player.finished.connect(_on_finished)


func _exit_tree() -> void:
	stop()
	_drop_jobs()
	for task in _tasks.keys():
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()


## True when `voice` is rendered to a clip here instead of being spoken by spd-say.
func renders(voice: String) -> bool:
	if not _rh_checked:
		_rh_checked = true
		_find_rhvoice()
	return _rh_voices.has(voice)


## Start rendering `text` so a later speak() of the same text plays at once.
## Does nothing for voices that are spoken by spd-say.
func prefetch(text: String, voice: String, rate: float, pitch: float) -> void:
	if not renders(voice):
		return
	var key := "%s|%s|%s|%s" % [voice, rate, pitch, text]
	if _clips.has(key):
		return
	var req := _next_req
	_next_req += 1
	var txt := _dir.path_join("%d.txt" % req)
	var wav := _dir.path_join("%d.wav" % req)
	var fa := FileAccess.open(txt, FileAccess.WRITE)
	if fa == null:
		_render_failed("cannot write " + txt)
		return
	fa.store_string(text)
	fa.close()
	var engine_rate := clampf(rate, RH_MIN_RATE, RH_MAX_RATE)
	var pid := OS.create_process(RH_TOOL, ["-p", voice,
		"-r", str(roundi(engine_rate * 100.0)),
		"-t", str(roundi(clampf(pitch, 0.5, 2.0) * 100.0)),
		"-i", txt, "-o", wav])
	if pid <= 0:
		_render_failed("could not start " + RH_TOOL)
		return
	_clips[key] = null
	_order.append(key)
	while _order.size() > 8:
		var old: String = _order.pop_front()
		if old == _want_key:
			_order.append(old)
			break
		_clips.erase(old)
	_jobs.append({"key": key, "pid": pid, "txt": txt, "wav": wav, "extra": rate / engine_rate})
	set_process(true)


func speak(text: String, voice: String, volume: int, rate: float, pitch: float, id: int) -> void:
	stop()
	if renders(voice):
		_player.volume_db = linear_to_db(clampf(volume / 100.0, 0.0001, 1.0))
		prefetch(text, voice, rate, pitch)
		if renders(voice):  # still true unless starting the render just failed
			_want_key = "%s|%s|%s|%s" % [voice, rate, pitch, text]
			_want_id = id
			_want = [text, voice, volume, rate, pitch, id]
			_play_if_ready()
			return
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
	_full = text
	_base = 0
	_rate_now = rate
	_resume_off = 0
	_launch()


func stop() -> void:
	_id = -1
	_paused = false
	_want_key = ""
	_want_id = -1
	_want = []
	_playing_id = -1
	_player.stream_paused = false
	_player.stop()
	_halt()


func pause() -> void:
	if _paused:
		return
	_paused = true
	_player.stream_paused = true
	if _id != -1:
		# The killed utterance can't report where it stopped, so estimate it from
		# the speaking time and resume a little before it, at a word start.
		if _pid > 0:
			var el := maxf(float(Time.get_ticks_msec() - _started_at) / 1000.0, 0.0)
			_resume_off = _base + resume_offset(_full.substr(_base), int(el * _rate_now * _cps))
		_halt()


func resume() -> void:
	if not _paused:
		return
	_paused = false
	_player.stream_paused = false
	if _id != -1:
		var rest := _full.substr(_resume_off)
		if rest.strip_edges().is_empty():
			_resume_off = 0
			rest = _full
		_args[_args.size() - 1] = rest
		_base = _resume_off
		_launch()
		resumed.emit(_id, _resume_off)


## Where resume() restarts `text` after about `progress` chars of it were heard:
## the start of the word cut off by the estimate, so no word is cut short and at
## most whole words are repeated.
static func resume_offset(text: String, progress: int) -> int:
	var off := clampi(progress, 0, text.length())
	while off > 0 and not text.substr(off - 1, 1).strip_edges().is_empty():
		off -= 1
	return off


## Speed up (speed > 1) or slow down 16-bit mono PCM without changing its pitch (WSOLA):
## 30 ms windows are overlapped at a new spacing, each taken from where the input best
## continues the previous window, within 10 ms of where it nominally belongs.
static func stretch(data: PackedByteArray, sample_rate: int, speed: float) -> PackedByteArray:
	var count := data.size() / 2
	var n := (sample_rate * 30 / 1000) & ~1
	var hs := n / 2
	var tol := sample_rate * 10 / 1000
	var x := PackedFloat32Array()
	x.resize(count + n + 2 * tol)  # zero-padded so the tail survives
	for i in count:
		x[i] = data.decode_s16(i * 2)
	var ha := hs * speed
	var last := x.size() - n
	var frames := int((last - tol) / ha) + 1
	if n < 16 or frames < 2:
		return data
	var w := PackedFloat32Array()
	w.resize(n)
	for i in n:
		w[i] = 0.5 - 0.5 * cos(TAU * i / n)
	var y := PackedFloat32Array()
	y.resize((frames - 1) * hs + n)
	for i in n:
		y[i] = x[i] * w[i]
	var prev := 0
	for k in range(1, frames):
		var nominal := int(k * ha)
		var target := mini(prev + hs, last)  # what would naturally follow the last frame
		var lo := maxi(0, nominal - tol)
		var hi := mini(last, nominal + tol)
		var best := mini(nominal, hi)
		var best_c := -INF
		# A coarse search first (every 4th position, every 8th sample), then around its best.
		var p := lo
		while p <= hi:
			var c := 0.0
			var i := 0
			while i < n:
				c += x[p + i] * x[target + i]
				i += 8
			if c > best_c:
				best_c = c
				best = p
			p += 4
		best_c = -INF
		var coarse := best
		for q in range(maxi(lo, coarse - 3), mini(hi, coarse + 3) + 1):
			var c := 0.0
			var i := 0
			while i < n:
				c += x[q + i] * x[target + i]
				i += 2
			if c > best_c:
				best_c = c
				best = q
		var o := k * hs
		for i in n:
			y[o + i] += x[best + i] * w[i]
		prev = best
	var out := PackedByteArray()
	out.resize(y.size() * 2)
	for i in y.size():
		out.encode_s16(i * 2, clampi(roundi(y[i]), -32768, 32767))
	return out


# --- internals ---------------------------------------------------------------

## Find the voices RHVoice-test can render: the ones speech-dispatcher's rhvoice
## module lists (an unknown name would silently get RHVoice's default voice).
func _find_rhvoice() -> void:
	if OS.execute("sh", ["-c", "command -v " + RH_TOOL]) != 0:
		return
	var out: Array = []
	if OS.execute("spd-say", ["--application-name", APP_NAME, "-o", "rhvoice", "-L"], out) != 0 or out.is_empty():
		return
	var lines: PackedStringArray = str(out[0]).split("\n", false)
	for i in range(1, lines.size()):  # the first line is the table's header
		var cols := lines[i].strip_edges().split(" ", false)
		if cols.size() >= 3:  # name (may have spaces), language, variant
			_rh_voices[" ".join(cols.slice(0, cols.size() - 2))] = true
	if _rh_voices.is_empty():
		return
	_dir = OS.get_cache_dir().path_join("bibliotheca-viva-tts")
	DirAccess.make_dir_recursive_absolute(_dir)
	for f in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir.path_join(f))
	AppLog.info("tts", "rendering %d RHVoice voices with %s" % [_rh_voices.size(), RH_TOOL])


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


## Learn the voice's speed from a finished utterance, so the resume offset follows
## the actual voice, engine and rate. Short and tiny utterances time unreliably.
func _learn_speed() -> void:
	if _args.is_empty() or _rate_now <= 0.0:
		return
	var secs := float(Time.get_ticks_msec() - _started_at) / 1000.0
	var chars := _args[_args.size() - 1].length()
	if secs <= 0.5 or chars < 40:
		return
	var cps := chars / secs / _rate_now
	if cps > 5.0 and cps < 40.0:
		_cps = lerpf(_cps, cps, 0.5)


## Stop the running utterance. Killing spd-say only drops its connection; the message
## it already handed to speech-dispatcher keeps playing, so it is cancelled as well.
## This waits for the cancel so it can't hit an utterance started right after.
func _halt() -> void:
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
	_check_jobs()
	if _launch_pending:
		_launch()
	elif _pid > 0 and not OS.is_process_running(_pid):
		var code := OS.get_process_exit_code(_pid)
		_pid = -1
		if code != 0:
			_fail("spd-say exited with code %d after %d ms" % [code, Time.get_ticks_msec() - _started_at])
			return
		var id := _id
		_id = -1
		_learn_speed()
		ended.emit(id)
	if not _launch_pending and _pid <= 0 and _jobs.is_empty():
		set_process(false)


## Hand the clips RHVoice-test has finished to a worker thread for loading.
func _check_jobs() -> void:
	for job in _jobs.duplicate():
		if OS.is_process_running(job.pid):
			continue
		_jobs.erase(job)
		var code := OS.get_process_exit_code(job.pid)
		DirAccess.remove_absolute(job.txt)
		if code != 0 or not FileAccess.file_exists(job.wav):
			_render_failed("%s exited with code %d" % [RH_TOOL, code])
			return
		var task := WorkerThreadPool.add_task(_load_clip.bind(job.key, job.wav, job.extra))
		_tasks[task] = true


## On a worker thread: read the clip, cut the silence around it and stretch it.
func _load_clip(key: String, wav: String, extra: float) -> void:
	var clip := WinVoice._load_trimmed(wav)
	DirAccess.remove_absolute(wav)
	if clip != null and not clip.stereo and absf(extra - 1.0) > 0.03:
		clip.data = stretch(clip.data, clip.mix_rate, extra)
	_clip_loaded.call_deferred(key, clip)


func _clip_loaded(key: String, clip: AudioStreamWAV) -> void:
	for task in _tasks.keys():
		if WorkerThreadPool.is_task_completed(task):
			WorkerThreadPool.wait_for_task_completion(task)  # frees the finished task
			_tasks.erase(task)
	if clip == null:
		_render_failed("bad audio from " + RH_TOOL)
		return
	if _clips.has(key):
		_clips[key] = clip
	_play_if_ready()


func _play_if_ready() -> void:
	if _want_key == "" or _clips.get(_want_key) == null:
		return
	_player.stream = _clips[_want_key]
	_playing_id = _want_id
	_want_key = ""
	_want_id = -1
	_want = []
	_player.play()
	_player.stream_paused = _paused


func _on_finished() -> void:
	var id := _playing_id
	_playing_id = -1
	if id != -1:
		ended.emit(id)


func _drop_jobs() -> void:
	for job in _jobs:
		OS.kill(job.pid)
		DirAccess.remove_absolute(job.txt)
		DirAccess.remove_absolute(job.wav)
	_jobs.clear()


## Rendering doesn't work: speak RHVoice voices through spd-say like the others from
## now on, starting with the utterance that is waiting for its clip.
func _render_failed(why: String) -> void:
	push_warning("LinuxVoice: no rendering, " + why)
	AppLog.info("tts", "LinuxVoice stopped rendering: " + why)
	_rh_voices.clear()
	_drop_jobs()
	_clips.clear()
	_order.clear()
	var redo := _want
	if not redo.is_empty():
		var was_paused := _paused
		speak(redo[0], redo[1], redo[2], redo[3], redo[4], redo[5])
		if was_paused:
			pause()


func _fail(why: String) -> void:
	push_warning("LinuxVoice disabled: " + why)
	AppLog.info("tts", "LinuxVoice disabled: " + why)
	failed.emit()
