extends Node
## Text-to-speech using the platform voices exposed by DisplayServer
## (Windows SAPI, macOS/iOS AVSpeech, Linux speech-dispatcher, Android TTS, Web Speech API).
##
## The reader hands over one item per paragraph ({text, kind}). Each paragraph is
## spoken as one utterance, or split into sentences in "sentence" mode, with
## configurable pauses between sentences, paragraphs and after headings.
## On Windows the audio is rendered and played by WinVoice, which trims the silence
## Windows voices add to every utterance. On Linux LinuxVoice speaks through spd-say,
## because Godot's speech-dispatcher code sends SSML some engines read out as text. On Android the BibliothecaVivaSpeech plugin
## (addons/android_speech) plays everything itself, so reading continues in the
## background (see "Android" below). Elsewhere, when a pause is 0 the next utterance
## is queued with the OS while the current one is still speaking.

signal state_changed(playing: bool)
signal paragraph_started(index: int)
## A new utterance of paragraph `paragraph` started: its sentence number in sentence mode.
signal sentence_started(paragraph: int, sentence: int)
signal word_boundary(paragraph: int, char_pos: int)
signal reached_end
signal sleep_triggered
signal sleep_changed
## Android: reading moved on to a chapter handed over with append_chapter() (delta > 0),
## or back to an earlier one from the notification. `items` now holds that chapter.
signal chapter_changed(delta: int)
## The list returned by voices() changed (Windows: the SAPI5 voices arrived or went away).
signal voices_changed

## Sleep timer choices in minutes; -1 means "at the end of this chapter".
const SLEEP_OPTIONS := [0, 5, 15, 30, 45, 60, 90, -1]
## Settings that change how paragraphs are split into utterances.
const RESPLIT_SETTINGS := ["tts_mode", "tts_max_chars", "tts_read_headings", "tts_skip_symbols"]

var items: Array = []           # [{text, kind}]
var source_owner := ""                 # who started playback: "reader" | "web" | ""
var current := -1               # paragraph index
var playing := false
var paused := false
var sleep_minutes := 0
var sleep_deadline := 0.0

var _chunks: PackedStringArray = []
var _chunk := 0
var _next_id := 1
var _active_id := -1
var _generation := 0             # bumps on stop/skip so stale timers and callbacks are ignored
var _in_gap := false
var _precise_waits := 0
var _queued: Array = []          # utterances handed to the OS ahead of time: [{id, para, chunk, chunks}]
var _resume_after_gap := Callable()
var _win: WinVoice               # gap-free Windows playback; null when not in use
var _linux: LinuxVoice           # Linux playback through spd-say; null when not in use
var _voices_cache: Array = []

var _droid: Object                # BibliothecaVivaSpeech plugin on Android; null elsewhere
var _session := 0                 # Android: identifies the current play() in the plugin's signals
var _flat: Array = []             # Android: one [chapter, paragraph, chunk] per utterance
var _chapters: Array = []         # Android: items of each chapter handed over since play()
var _titles := PackedStringArray()
var _base := 0                    # Android: index in _chapters of the chapter `items` is from
var _pos := -1                    # Android: index in _flat being spoken
var _pending := -1                # Android: latest utterance reported by the plugin, not yet applied
var _book_title := ""             # Android: shown in the media notification


func _ready() -> void:
	if not is_supported():
		return
	DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_ENDED, _on_ended)
	DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_CANCELED, _on_canceled)
	DisplayServer.tts_set_utterance_callback(DisplayServer.TTS_UTTERANCE_BOUNDARY, _on_boundary)
	if WinVoice.available():
		_win = WinVoice.new()
		add_child(_win)
		_win.ended.connect(_on_ended)
		_win.failed.connect(_on_win_failed)
		_win.voices_changed.connect(voices_changed.emit)
	elif LinuxVoice.available():
		_linux = LinuxVoice.new()
		add_child(_linux)
		_linux.ended.connect(_on_ended)
		_linux.failed.connect(_on_linux_failed)
	if Engine.has_singleton("BibliothecaVivaSpeech"):
		_droid = Engine.get_singleton("BibliothecaVivaSpeech")
		_droid.connect("chunk_started", _on_droid_chunk)
		_droid.connect("state_changed", _on_droid_state)
		_droid.connect("finished", _on_droid_finished)
		_droid.connect("sleep_stopped", _on_droid_sleep)
		_droid_configure()
		Settings.changed.connect(func(key): if key in ["tts_rate", "tts_pitch", "tts_volume"]: _droid_configure())
	Settings.changed.connect(func(key): if key in RESPLIT_SETTINGS: _resplit())


func is_supported() -> bool:
	return DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH)


## [{id, name, language}]. On Windows this includes the SAPI5 voices listed by
## WinVoice (e.g. RHVoice), which Godot itself doesn't see, once its helper is up.
func voices() -> Array:
	if not is_supported():
		return []
	if _voices_cache.is_empty():
		_voices_cache = DisplayServer.tts_get_voices()
	if _win and not _win.sapi_voices.is_empty():
		return _voices_cache + _win.sapi_voices
	return _voices_cache.duplicate()


## On Android the voice comes from the system TTS engine settings rather than an in-app choice.
func uses_system_voice() -> bool:
	return OS.get_name() == "Android"


## Empty on Android, where Godot then leaves the engine's default voice in place.
func voice_id() -> String:
	if uses_system_voice():
		return ""
	var wanted: String = Settings.get_value("tts_voice")
	if wanted.begins_with(WinVoice.SAPI_PREFIX) and _win and not _win.voices_known():
		return wanted  # the helper is still starting; it will know the voice
	var all := voices()
	for v in all:
		if v.id == wanted:
			return wanted
	var english := DisplayServer.tts_get_voices_for_language("en") if is_supported() else PackedStringArray()
	if english.size() > 0:
		return english[0]
	return all[0].id if all.size() > 0 else ""


func voice_name() -> String:
	var id := voice_id()
	for v in voices():
		if v.id == id:
			return v.name
	return "System voice"


## Opens Android's text-to-speech settings (engine, language, voice). Returns false if it couldn't.
func open_system_settings() -> bool:
	var runtime := Engine.get_singleton("AndroidRuntime") if Engine.has_singleton("AndroidRuntime") else null
	if runtime == null:
		return false
	var activity = runtime.getActivity()
	var intent_class = JavaClassWrapper.wrap("android.content.Intent")
	for action in ["com.android.settings.TTS_SETTINGS", "android.settings.SETTINGS"]:
		activity.startActivity(intent_class.Intent(action))
		if JavaClassWrapper.get_exception() == null:
			return true
	return false


# --- playback ----------------------------------------------------------------

## Start reading `paras` ([{text, kind}] or plain strings) from paragraph `start`.
## `title` and `subtitle` (book and chapter) are shown in Android's media notification.
func play(paras: Array, start := 0, who := "reader", title := "", subtitle := "") -> void:
	_halt()
	source_owner = who
	items = _normalize(paras)
	if items.is_empty():
		return
	playing = true
	paused = false
	if _droid:
		_droid_play(clampi(start, 0, items.size() - 1), title, subtitle)
	else:
		_start_paragraph(clampi(start, 0, items.size() - 1))
	state_changed.emit(true)


## True when chapters can be handed over in advance with append_chapter() (Android),
## so reading can carry on into them while the app is in the background.
func reads_ahead() -> bool:
	return _droid != null


## How many chapters after the current one have been handed over with append_chapter().
func chapters_ahead() -> int:
	return _chapters.size() - 1 - _base if _droid and playing else 0


## Android: queue the chapter after the last one handed over, to follow without a break.
func append_chapter(paras: Array, subtitle := "") -> void:
	if not _droid or not playing:
		return
	_chapters.append(_normalize(paras))
	_titles.append(subtitle)
	var batch := _droid_flatten(_chapters.size() - 1)
	_droid.append(_session, batch.texts, batch.gaps, batch.chapters, _titles)


func toggle() -> void:
	if not playing:
		return
	if _droid:
		paused = not paused
		if paused:
			_droid.pause()
		else:
			_droid_configure()
			_droid.resume()
	elif paused:
		paused = false
		if _in_gap:
			pass  # the gap timer continues on its own
		elif _active_id != -1:
			_tts_resume()
		else:
			_speak_chunk()
	else:
		paused = true
		if not _in_gap:
			_tts_pause()
	state_changed.emit(not paused)


func stop() -> void:
	var was_playing := playing
	_halt()
	if was_playing:
		state_changed.emit(false)


## Jump by whole paragraphs (0 restarts the current one, e.g. after a speed change).
func skip(delta: int) -> void:
	if not playing or items.is_empty():
		return
	var target := clampi(current + delta, 0, items.size() - 1)
	if _droid:
		var i := _droid_index_of(target)
		_droid_seek(i if i != -1 else _pos)
		return
	_cancel_utterance()
	paused = false
	_start_paragraph(target)
	state_changed.emit(true)


## Jump by sentences inside the current paragraph (sentence mode), else by paragraphs.
func skip_sentence(delta: int) -> void:
	if not playing:
		return
	if _droid:
		var i := _pos + delta
		if i < 0 or i >= _flat.size() or _flat[i][0] != _base:
			skip(signi(delta))
		else:
			_droid_seek(i)
		return
	var target := _chunk + delta
	if target < 0 or target >= _chunks.size():
		skip(signi(delta))
		return
	_cancel_utterance()
	paused = false
	_chunk = target
	_speak_chunk()


## Speak a single line now (used by "Test voice" and rule previews).
func preview(text: String) -> void:
	stop()
	source_owner = ""
	if is_supported() and text.strip_edges() != "":
		if _win:
			_win.speak(text, voice_id(), int(Settings.get_value("tts_volume")),
				float(Settings.get_value("tts_rate")), float(Settings.get_value("tts_pitch")), 0)
		elif _linux:
			_linux.speak(text, voice_id(), int(Settings.get_value("tts_volume")),
				float(Settings.get_value("tts_rate")), float(Settings.get_value("tts_pitch")), 0)
		else:
			DisplayServer.tts_speak(text, voice_id(), int(Settings.get_value("tts_volume")),
				float(Settings.get_value("tts_pitch")), float(Settings.get_value("tts_rate")), 0, true)


func is_active() -> bool:
	return playing and not paused


# --- sleep timer -------------------------------------------------------------

func set_sleep(minutes: int) -> void:
	sleep_minutes = minutes
	sleep_deadline = Time.get_unix_time_from_system() + minutes * 60.0 if minutes > 0 else 0.0
	if _droid:
		_droid.setSleep(minutes * 60 if minutes > 0 else 0, minutes == -1)
	sleep_changed.emit()


func cycle_sleep() -> void:
	var i := SLEEP_OPTIONS.find(sleep_minutes)
	set_sleep(SLEEP_OPTIONS[(i + 1) % SLEEP_OPTIONS.size()])


func sleep_label() -> String:
	if sleep_minutes == -1:
		return "End of chapter"
	if sleep_minutes == 0:
		return "Off"
	var left := maxf(0.0, sleep_deadline - Time.get_unix_time_from_system())
	return "%d:%02d" % [int(left / 60), int(left) % 60]


## True when reading should stop at the end of this chapter instead of continuing.
func stops_at_chapter_end() -> bool:
	return sleep_minutes == -1


# --- internals ---------------------------------------------------------------

func _halt() -> void:
	_generation += 1
	_queued.clear()
	playing = false
	paused = false
	_in_gap = false
	_active_id = -1
	_pending = -1
	if is_supported():
		_tts_stop()


func _cancel_utterance() -> void:
	_generation += 1
	_queued.clear()
	_in_gap = false
	_active_id = -1
	_tts_stop()


func _normalize(paras: Array) -> Array:
	return paras.map(func(p): return p if p is Dictionary else {"text": str(p), "kind": "p"})


func _start_paragraph(index: int) -> void:
	current = index
	_chunk = 0
	var item: Dictionary = items[index]
	_chunks = _split(item)
	paragraph_started.emit(index)
	if _chunks.is_empty():
		_after_chunk.call_deferred(_generation)
		return
	_speak_chunk()


func _speak_chunk() -> void:
	if sleep_deadline > 0 and Time.get_unix_time_from_system() >= sleep_deadline:
		set_sleep(0)
		stop()
		sleep_triggered.emit()
		return
	_active_id = _submit(_chunks[_chunk])
	sentence_started.emit(current, _chunk)
	_queue_ahead()


func _submit(text: String) -> int:
	var id := _next_id
	_next_id += 1
	if _win:
		_win.speak(text, voice_id(), int(Settings.get_value("tts_volume")),
			float(Settings.get_value("tts_rate")), float(Settings.get_value("tts_pitch")), id)
	elif _linux:
		_linux.speak(text, voice_id(), int(Settings.get_value("tts_volume")),
			float(Settings.get_value("tts_rate")), float(Settings.get_value("tts_pitch")), id)
	else:
		DisplayServer.tts_speak(text, voice_id(), int(Settings.get_value("tts_volume")),
			float(Settings.get_value("tts_pitch")), float(Settings.get_value("tts_rate")), id, false)
	return id


## Get the next utterance ready. WinVoice renders it in the background; with OS
## voices it is queued with the OS, but only when the pause before it is 0
## (not with LinuxVoice: one spd-say per utterance can't keep them in order).
func _queue_ahead() -> void:
	if not _queued.is_empty():
		return
	var next := _next_chunk()
	if next.is_empty():
		return
	if _win:
		_win.prefetch(next.chunks[next.chunk], voice_id(), float(Settings.get_value("tts_rate")), float(Settings.get_value("tts_pitch")))
		return
	if _linux or _gap_ms(items, current, _chunk, _chunks) > 0:
		return
	next.id = _submit(next.chunks[next.chunk])
	_queued.append(next)


## The chunk after the current one: {para, chunk, chunks}, or {} at the end or
## when the next paragraph is empty (the normal path steps over those).
func _next_chunk() -> Dictionary:
	var para := current
	var chunk := _chunk + 1
	var chunks := _chunks
	if chunk >= chunks.size():
		para += 1
		if para >= items.size():
			return {}
		chunks = _split(items[para])
		chunk = 0
		if chunks.is_empty():
			return {}
	return {"para": para, "chunk": chunk, "chunks": chunks}


func _tts_stop() -> void:
	if _droid:
		_droid.stop()
	elif _win:
		_win.stop()
	elif _linux:
		_linux.stop()
	else:
		DisplayServer.tts_stop()


func _tts_pause() -> void:
	if _win:
		_win.pause()
	elif _linux:
		_linux.pause()
	else:
		DisplayServer.tts_pause()


func _tts_resume() -> void:
	if _win:
		_win.resume()
	elif _linux:
		_linux.resume()
	else:
		DisplayServer.tts_resume()


## The helper can't be used: switch to Godot's own TTS and redo the current chunk.
func _on_win_failed() -> void:
	_win.stop()
	_win = null
	voices_changed.emit()
	if playing and _active_id != -1:
		var was_paused := paused
		_cancel_utterance()
		_speak_chunk()
		if was_paused:
			_tts_pause()


## spd-say can't be used: switch to Godot's own TTS and redo the current chunk.
func _on_linux_failed() -> void:
	_linux.stop()
	_linux.queue_free()
	_linux = null
	if playing and _active_id != -1:
		var was_paused := paused
		_cancel_utterance()
		_speak_chunk()
		if was_paused:
			_tts_pause()


## Pause in ms after chunk `chunk` of paragraph `para` of `paras`.
func _gap_ms(paras: Array, para: int, chunk: int, chunks: PackedStringArray) -> int:
	if chunks.is_empty():
		return 0
	if chunk + 1 < chunks.size():
		return int(Settings.get_value("tts_pause_sentence"))
	if paras[para].get("kind", "p") != "p":
		return int(Settings.get_value("tts_pause_heading"))
	return int(Settings.get_value("tts_pause_paragraph"))


## The utterance being spoken within the current paragraph (its sentence in sentence mode).
func current_sentence() -> int:
	return _chunk


## The utterances a paragraph item ({text, kind}) is read as.
func split(item: Dictionary) -> PackedStringArray:
	return _split(item)


func _split(item: Dictionary) -> PackedStringArray:
	# Blank-looking characters strip_edges() keeps: zero-width ones and the Hangul and
	# Braille fillers sites use for empty lines (U+3164 counts as a letter otherwise).
	var text: String = HtmlText._re("[\\x{200B}-\\x{200D}\\x{2060}\\x{FEFF}\\x{115F}\\x{1160}\\x{3164}\\x{FFA0}\\x{2800}]").sub(str(item.text), " ", true).strip_edges()
	var heading: bool = item.get("kind", "p") != "p"
	if text == "" or (heading and not Settings.get_value("tts_read_headings")):
		return []
	if Settings.get_value("tts_skip_symbols") and not HtmlText._re("[\\p{L}\\p{N}]").search(text):
		return []
	var max_len := int(Settings.get_value("tts_max_chars"))
	var parts := split_sentences(text) if Settings.get_value("tts_mode") == "sentence" or text.length() > max_len else PackedStringArray([text])
	return parts


## Split text into sentences, keeping closing quotes with their sentence and
## not breaking after common abbreviations.
static func split_sentences(text: String) -> PackedStringArray:
	const ABBREV := ["mr", "mrs", "ms", "dr", "st", "sr", "jr", "prof", "vs", "etc", "e.g", "i.e", "mt", "no", "lt", "col", "gen", "capt", "sgt"]
	var out := PackedStringArray()
	var start := 0
	for m in HtmlText._re("[.!?…]+[\"”’')\\]]*(?=\\s+)").search_all(text):
		var piece := text.substr(start, m.get_end() - start).strip_edges()
		var last_word := piece.get_slice(" ", piece.get_slice_count(" ") - 1).to_lower().trim_suffix(".")
		if last_word in ABBREV or (last_word.length() == 1 and last_word.to_upper() != last_word.to_lower()):
			continue  # "Mr." or an initial like "J."
		if piece != "":
			out.append(piece)
		start = m.get_end()
	var tail := text.substr(start).strip_edges()
	if tail != "":
		out.append(tail)
	return out


func _on_ended(id: int) -> void:
	if id != _active_id:
		return
	_active_id = -1
	if _queued.is_empty():
		_after_chunk.call_deferred(_generation)
		return
	# The OS is already speaking the queued utterance; just catch up with it.
	var next: Dictionary = _queued.pop_front()
	_active_id = next.id
	_chunk = next.chunk
	_chunks = next.chunks
	if next.para != current:
		current = next.para
		paragraph_started.emit(current)
	sentence_started.emit(current, _chunk)
	if sleep_deadline > 0 and Time.get_unix_time_from_system() >= sleep_deadline:
		set_sleep(0)
		stop()
		sleep_triggered.emit()
		return
	_queue_ahead()


func _on_canceled(id: int) -> void:
	if id == _active_id:
		_active_id = -1


func _on_boundary(pos: int, id: int) -> void:
	if id == _active_id:
		word_boundary.emit(current, pos)


## Low-processor mode sleeps between frames, which stretches short timers by tens of ms;
## turn it off while a pause is being timed so small pauses stay small.
func _wait_ms(ms: int) -> void:
	_precise_waits += 1
	OS.low_processor_usage_mode = false
	await get_tree().create_timer(ms / 1000.0, true, false, true).timeout
	_precise_waits -= 1
	if _precise_waits == 0:
		OS.low_processor_usage_mode = ProjectSettings.get_setting("application/run/low_processor_mode")


## Called after each utterance: wait the configured pause, then continue.
func _after_chunk(gen: int) -> void:
	if gen != _generation or not playing:
		return
	var last_in_para := _chunk + 1 >= _chunks.size()
	var ms := _gap_ms(items, current, _chunk, _chunks)
	if ms > 0:
		_in_gap = true
		await _wait_ms(ms)
		_in_gap = false
		while paused and gen == _generation:
			await get_tree().create_timer(0.1).timeout
		if gen != _generation or not playing:
			return
	if not last_in_para:
		_chunk += 1
		_speak_chunk()
	elif current + 1 < items.size():
		_start_paragraph(current + 1)
	else:
		playing = false
		state_changed.emit(false)
		reached_end.emit()


# --- Android -----------------------------------------------------------------
# Godot's main loop stops while the app is in the background, so on Android the
# plugin gets the whole list of utterances with the pause after each, and plays it
# on its own behind a media notification. The reader hands over the next chapters
# in advance with append_chapter(). The plugin reports which utterance it's on, and
# _flat maps that back to a chapter and paragraph. Reports that arrive in a burst
# (after the app comes back to the foreground) are applied once, for the latest.

func _droid_configure() -> void:
	_droid.configure(roundi(float(Settings.get_value("tts_rate")) * 100),
		roundi(float(Settings.get_value("tts_pitch")) * 100), int(Settings.get_value("tts_volume")))


func _droid_play(start: int, title: String, subtitle: String) -> void:
	_session += 1
	_flat.clear()
	_book_title = title
	_chapters = [items]
	_titles = PackedStringArray([subtitle])
	_base = 0
	var batch := _droid_flatten(0)
	var first := _droid_index_of(start)
	if first == -1:  # nothing left to read in this chapter
		_on_droid_finished.call_deferred(_session)
		return
	_droid_configure()
	_droid.play(_session, batch.texts, batch.gaps, batch.chapters, _titles, title, first)
	_droid_apply(first)


## A setting changed how paragraphs are split (e.g. sentence mode was turned on):
## split again and carry on from the start of the current paragraph.
func _resplit() -> void:
	if not playing or current < 0:
		return
	var was_paused := paused
	if _droid:
		_session += 1
		_flat.clear()
		var texts := PackedStringArray()
		var gaps := PackedInt32Array()
		var chapters := PackedInt32Array()
		for ch in _chapters.size():
			var batch := _droid_flatten(ch)
			texts.append_array(batch.texts)
			gaps.append_array(batch.gaps)
			chapters.append_array(batch.chapters)
		var first := _droid_index_of(current)
		if first == -1:
			first = _droid_index_of(0)
		if first == -1:
			return  # nothing in this chapter is read any more; carry on with the old split
		_pending = -1
		_droid_configure()
		_droid.play(_session, texts, gaps, chapters, _titles, _book_title, first)
		paused = false
		_droid_apply(first)
	else:
		_cancel_utterance()
		paused = false
		_start_paragraph(current)
	if was_paused:
		toggle()


## Splits chapter `ch` of _chapters into utterances, adds them to _flat and returns
## them for the plugin. The pause after a chapter's last utterance is the chapter pause.
func _droid_flatten(ch: int) -> Dictionary:
	var paras: Array = _chapters[ch]
	var texts := PackedStringArray()
	var gaps := PackedInt32Array()
	var chapters := PackedInt32Array()
	for para in paras.size():
		var chunks := _split(paras[para])
		for chunk in chunks.size():
			_flat.append([ch, para, chunk])
			texts.append(chunks[chunk])
			gaps.append(_gap_ms(paras, para, chunk, chunks))
			chapters.append(ch)
	if not gaps.is_empty():
		gaps[gaps.size() - 1] = int(Settings.get_value("tts_pause_chapter"))
	return {"texts": texts, "gaps": gaps, "chapters": chapters}


## First utterance of paragraph `para` (or a later one) in the current chapter, or -1.
func _droid_index_of(para: int) -> int:
	for i in _flat.size():
		if _flat[i][0] == _base and _flat[i][1] >= para:
			return i
	return -1


func _droid_seek(i: int) -> void:
	_droid_configure()
	_droid.seek(i)
	paused = false
	_pending = -1
	_droid_apply(i)
	state_changed.emit(true)


func _droid_apply(i: int) -> void:
	var entry: Array = _flat[i]
	_pos = i
	_chunk = entry[2]
	if entry[0] != _base:
		var delta: int = entry[0] - _base
		_base = entry[0]
		items = _chapters[_base]
		current = -1
		chapter_changed.emit(delta)
	if entry[1] != current:
		current = entry[1]
		paragraph_started.emit(current)
	sentence_started.emit(current, _chunk)


func _droid_sync() -> void:
	if _pending != -1 and playing:
		_droid_apply(_pending)
	_pending = -1


func _on_droid_chunk(session: int, index: int) -> void:
	if session != _session or not playing or index >= _flat.size():
		return
	if _pending == -1:
		_droid_sync.call_deferred()
	_pending = index


## Paused, resumed or stopped, possibly from the notification or by another app taking over audio.
func _on_droid_state(session: int, is_playing: bool, is_paused: bool) -> void:
	if session != _session or not playing:
		return
	_droid_sync()
	if not is_playing:
		stop()
	elif is_paused != paused:
		paused = is_paused
		state_changed.emit(not paused)


func _on_droid_finished(session: int) -> void:
	if session != _session or not playing:
		return
	_droid_sync()
	playing = false
	paused = false
	state_changed.emit(false)
	reached_end.emit()


func _on_droid_sleep(session: int) -> void:
	if session != _session or not playing:
		return
	_droid_sync()
	set_sleep(0)
	stop()
	sleep_triggered.emit()
