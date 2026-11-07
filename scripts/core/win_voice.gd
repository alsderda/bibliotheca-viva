class_name WinVoice
extends Node
## Windows speech without the gaps.
##
## Godot's Windows TTS plays each utterance exactly as the voice renders it, and
## Windows voices pad every utterance with ~0.2 s of silence at the start and
## ~0.8 s at the end, so consecutive sentences always have about a second of dead air.
## Here a small PowerShell helper renders the audio with the same voices, the padding
## is trimmed, and the clips are played with an AudioStreamPlayer. The next clip is
## rendered while the current one plays, so the configured pauses are the only gaps.
##
## Godot only sees the modern (OneCore) voices. The helper also lists the classic
## SAPI5 voices (third-party engines such as RHVoice install only those) and renders
## them with System.Speech. Their ids start with SAPI_PREFIX.

signal ended(id: int)
signal voices_changed  # the helper has listed its SAPI5 voices
signal failed  # the helper is unusable; the caller should fall back to DisplayServer TTS

## Silence kept around the speech so word edges are not clipped.
const LEAD_KEEP_MS := 20
const TRAIL_KEEP_MS := 60
const SILENCE := 200  # sample amplitude treated as silence
const SAPI_PREFIX := "sapi:"

const HELPER := r"""
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer,Windows.Media,ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.DataReader,Windows.Storage.Streams,ContentType=WindowsRuntime]
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($op, $type) { $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait(-1) | Out-Null; $t.Result }
function Dec($s) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) }
$out = [Console]::Out
$dir = Dec ([Console]::In.ReadLine())
$synth = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
$voices = @{}
foreach ($v in [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices) { $voices[$v.Id] = $v }
function Enc($s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
$sapi = $null
try {
	Add-Type -AssemblyName System.Speech
	$sapi = New-Object System.Speech.Synthesis.SpeechSynthesizer
	foreach ($v in $sapi.GetInstalledVoices()) {
		if ($v.Enabled) { $out.WriteLine("VOICE`t" + (Enc $v.VoiceInfo.Name) + "`t" + $v.VoiceInfo.Culture.Name) }
	}
	$sapiFmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(24000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
} catch { $sapi = $null }

# SAPI voices often can't reach the requested speed: SAPI's rate is a whole step from
# -10 to 10, and some engines cap it (RHVoice stops at about 2x). Each voice's real
# speed at a rate step is measured once; the clip is rendered at the closest step that
# isn't too fast, and the rest is made up by time-stretching (WSOLA, keeps the pitch).
$stretchCode = @'
using System;
using System.IO;
public static class SrStretch {
	public static short[] Samples(byte[] b) { short[] s = new short[b.Length / 2]; Buffer.BlockCopy(b, 0, s, 0, s.Length * 2); return s; }
	public static int SpeechLength(short[] s) {
		int a = 0; while (a < s.Length && Math.Abs((int)s[a]) < 200) a++;
		int z = s.Length - 1; while (z > a && Math.Abs((int)s[z]) < 200) z--;
		return Math.Max(1, z - a);
	}
	public static short[] Wsola(short[] input, int sr, double speed) {
		int n = (sr * 30 / 1000) & ~1, hs = n / 2, tol = sr * 10 / 1000;
		short[] x = new short[input.Length + n + 2 * tol];  // padded so the tail survives
		Array.Copy(input, x, input.Length);
		double ha = hs * speed;
		int frames = (int)((x.Length - n - tol) / ha) + 1;
		if (x.Length - n - tol < 0 || frames < 2) return input;
		double[] w = new double[n];
		for (int i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / n);
		double[] y = new double[(frames - 1) * hs + n];
		int prev = 0;
		for (int i = 0; i < n; i++) y[i] += x[i] * w[i];
		for (int k = 1; k < frames; k++) {
			int nominal = (int)(k * ha);
			int target = Math.Min(prev + hs, x.Length - n);  // what would naturally follow the last frame
			int lo = Math.Max(0, nominal - tol), hi = Math.Min(x.Length - n, nominal + tol);
			int best = Math.Min(nominal, hi); double bestC = double.MinValue;
			for (int p = lo; p <= hi; p++) {
				double c = 0;
				for (int i = 0; i < n; i += 2) c += (double)x[p + i] * x[target + i];
				if (c > bestC) { bestC = c; best = p; }
			}
			int o = k * hs;
			for (int i = 0; i < n; i++) y[o + i] += x[best + i] * w[i];
			prev = best;
		}
		short[] r = new short[y.Length];
		for (int i = 0; i < y.Length; i++) r[i] = (short)Math.Max(-32768, Math.Min(32767, Math.Round(y[i])));
		return r;
	}
	public static void WriteWav(string path, short[] s, int sr) {
		byte[] b = new byte[s.Length * 2];
		Buffer.BlockCopy(s, 0, b, 0, b.Length);
		using (BinaryWriter f = new BinaryWriter(File.Create(path))) {
			f.Write(new byte[] { 82, 73, 70, 70 }); f.Write(36 + b.Length);
			f.Write(new byte[] { 87, 65, 86, 69, 102, 109, 116, 32 }); f.Write(16);
			f.Write((short)1); f.Write((short)1); f.Write(sr); f.Write(sr * 2); f.Write((short)2); f.Write((short)16);
			f.Write(new byte[] { 100, 97, 116, 97 }); f.Write(b.Length); f.Write(b);
		}
	}
}
'@
$stretchLoaded = $false
$sapiLens = @{}
function SapiRender($text, [bool]$ssml) {
	$ms = New-Object IO.MemoryStream
	$sapi.SetOutputToAudioStream($ms, $sapiFmt)
	try { if ($ssml) { $sapi.SpeakSsml($text) } else { $sapi.Speak($text) } } finally { $sapi.SetOutputToNull() }
	return ,[SrStretch]::Samples($ms.ToArray())
}
# Speech length of a test sentence with the selected voice at rate step $r.
function SapiLen($name, [int]$r) {
	$k = "$name|$r"
	if (-not $sapiLens.ContainsKey($k)) {
		$sapi.Rate = $r
		$sapiLens[$k] = [SrStretch]::SpeechLength((SapiRender 'The rain had not stopped for three days, and the river climbed the steps of the mill.' $false))
	}
	return $sapiLens[$k]
}
$out.WriteLine('READY'); $out.Flush()
while ($true) {
	$line = [Console]::In.ReadLine()
	if ($line -eq $null) { break }
	$f = $line.Split("`t")
	try {
		$voice = Dec $f[1]
		$rate = [double]::Parse($f[2], [Globalization.CultureInfo]::InvariantCulture)
		$pitch = [double]::Parse($f[3], [Globalization.CultureInfo]::InvariantCulture)
		$path = Join-Path $dir ($f[0] + '.wav')
		if ($voice.StartsWith('sapi:')) {
			if (-not $stretchLoaded) { Add-Type -TypeDefinition $stretchCode; $stretchLoaded = $true }
			$name = $voice.Substring(5)
			$sapi.SelectVoice($name)
			# Nominally +10 is 3x and -10 is 1/3x; step down while the measured speed is too fast.
			$r = [int][Math]::Max(-10, [Math]::Min(10, [Math]::Round(10 * [Math]::Log($rate) / [Math]::Log(3))))
			$speed = (SapiLen $name 0) / (SapiLen $name $r)
			while ($speed -gt $rate * 1.03 -and $r -gt -10) { $r--; $speed = (SapiLen $name 0) / (SapiLen $name $r) }
			$sapi.Rate = $r
			$text = Dec $f[4]
			$pct = [int][Math]::Round(($pitch - 1) * 100)
			if ($pct -ne 0) {
				$sign = if ($pct -gt 0) { '+' } else { '' }
				$lang = $sapi.Voice.Culture.Name
				$esc = [Security.SecurityElement]::Escape($text)
				$samples = SapiRender "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='$lang'><prosody pitch='$sign$pct%'>$esc</prosody></speak>" $true
			} else {
				$samples = SapiRender $text $false
			}
			$extra = $rate / $speed
			if ([Math]::Abs($extra - 1) -gt 0.03) { $samples = [SrStretch]::Wsola($samples, 24000, $extra) }
			[SrStretch]::WriteWav($path, $samples, 24000)
			$out.WriteLine($f[0] + "`tOK")
			$out.Flush()
			continue
		}
		if ($voices.ContainsKey($voice) -and $synth.Voice.Id -ne $voice) { $synth.Voice = $voices[$voice] }
		$synth.Options.SpeakingRate = $rate
		$synth.Options.AudioPitch = $pitch
		$stream = Await ($synth.SynthesizeTextToStreamAsync((Dec $f[4]))) ([Windows.Media.SpeechSynthesis.SpeechSynthesisStream])
		$reader = New-Object Windows.Storage.Streams.DataReader($stream.GetInputStreamAt(0))
		$size = [uint32]$stream.Size
		$null = Await ($reader.LoadAsync($size)) ([uint32])
		$bytes = New-Object byte[] $size
		$reader.ReadBytes($bytes)
		$reader.Dispose(); $stream.Dispose()
		[IO.File]::WriteAllBytes($path, $bytes)
		$out.WriteLine($f[0] + "`tOK")
	} catch {
		$out.WriteLine($f[0] + "`tERR`t" + ($_.Exception.Message -replace '\s+', ' '))
	}
	$out.Flush()
}
"""

var _pid := -1
var _pipe: FileAccess
var _thread: Thread
var _dir := ""
var _ready_ok := false
var _broken := false
var _next_req := 1
var _clips := {}        # key -> AudioStreamWAV, or null while being rendered
var _req_key := {}      # request id -> key
var _order: Array = []  # keys, oldest first, to bound the cache
var _want_key := ""     # clip to play as soon as it is rendered
var _want_id := -1
var _playing_id := -1
var _paused := false
var _player: AudioStreamPlayer
var _ended_at := 0
## Longest time from one clip ending to the next starting, in ms (for the selftest).
var max_gap_ms := 0
## SAPI5 voices listed by the helper: [{id, name, language}], ids prefixed with SAPI_PREFIX.
var sapi_voices: Array = []


static func available() -> bool:
	return OS.get_name() == "Windows" and DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH)


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	add_child(_player)
	_player.finished.connect(_on_finished)
	_start()


func _exit_tree() -> void:
	var t := Time.get_ticks_msec()
	if _pid > 0:
		OS.kill(_pid)
		_pid = -1
	if _pipe:
		_pipe.close()
	AppLog.info("close", "Windows voice helper stopped in %d ms" % AppLog.since(t))
	if _thread and _thread.is_started():
		t = Time.get_ticks_msec()
		_thread.wait_to_finish()
		AppLog.info("close", "Windows voice reader thread finished in %d ms" % AppLog.since(t))


func is_broken() -> bool:
	return _broken


## True once the helper has listed its voices (or failed), so sapi_voices is final.
func voices_known() -> bool:
	return _ready_ok or _broken


## Start rendering `text` so a later speak() of the same text plays at once.
func prefetch(text: String, voice: String, rate: float, pitch: float) -> void:
	var key := _key(text, voice, rate, pitch)
	if _clips.has(key) or _broken:
		return
	_clips[key] = null
	_order.append(key)
	while _order.size() > 8:
		var old: String = _order.pop_front()
		if old != _want_key:
			_clips.erase(old)
	var req := _next_req
	_next_req += 1
	_req_key[req] = key
	var line := "%d\t%s\t%s\t%s\t%s" % [req, Marshalls.utf8_to_base64(voice), str(clampf(rate, 0.5, 6.0)), str(clampf(pitch, 0.0, 2.0)), Marshalls.utf8_to_base64(text)]
	_pipe.store_line(line)
	_pipe.flush()


func speak(text: String, voice: String, volume: int, rate: float, pitch: float, id: int) -> void:
	stop()
	_player.volume_db = linear_to_db(clampf(volume / 100.0, 0.0001, 1.0))
	prefetch(text, voice, rate, pitch)
	_want_key = _key(text, voice, rate, pitch)
	_want_id = id
	_play_if_ready()


func stop() -> void:
	_want_key = ""
	_want_id = -1
	_playing_id = -1
	_paused = false
	_player.stream_paused = false
	_player.stop()


func pause() -> void:
	_paused = true
	_player.stream_paused = true


func resume() -> void:
	_paused = false
	_player.stream_paused = false


# --- internals ---------------------------------------------------------------

func _key(text: String, voice: String, rate: float, pitch: float) -> String:
	return "%s|%s|%s|%s" % [voice, rate, pitch, text]


func _start() -> void:
	_dir = OS.get_cache_dir().path_join("serial-reader-tts")
	DirAccess.make_dir_recursive_absolute(_dir)
	for f in DirAccess.get_files_at(_dir):
		DirAccess.remove_absolute(_dir.path_join(f))
	var script := _dir.path_join("helper.ps1")
	var fa := FileAccess.open(script, FileAccess.WRITE)
	if fa == null:
		_fail("cannot write helper script")
		return
	fa.store_string(HELPER)
	fa.close()
	var proc := OS.execute_with_pipe("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script])
	if proc.is_empty():
		_fail("cannot start powershell")
		return
	_pid = proc.pid
	_pipe = proc.stdio
	_pipe.store_line(Marshalls.utf8_to_base64(_dir))
	_pipe.flush()
	_thread = Thread.new()
	_thread.start(_read_loop.bind(_pipe))


func _read_loop(pipe: FileAccess) -> void:
	while pipe.is_open():
		var line := pipe.get_line()
		if pipe.get_error() != OK and line == "":
			break
		if line != "":
			_on_line.call_deferred(line.strip_edges())
	_on_line.call_deferred("EXIT")


func _on_line(line: String) -> void:
	if line.begins_with("VOICE\t"):
		var v := line.split("\t")
		if v.size() >= 3:
			var vname := Marshalls.base64_to_utf8(v[1])
			sapi_voices.append({"id": SAPI_PREFIX + vname, "name": vname, "language": v[2].replace("-", "_")})
		return
	if line == "READY":
		_ready_ok = true
		voices_changed.emit()
		return
	if line == "EXIT":
		if _pid > 0:
			_fail("helper exited")
		return
	var f := line.split("\t")
	var req := f[0].to_int()
	if not _req_key.has(req):
		return
	var key: String = _req_key[req]
	_req_key.erase(req)
	var path := _dir.path_join("%d.wav" % req)
	if f.size() < 2 or f[1] != "OK":
		push_warning("WinVoice: " + line)
		_fail("render failed")
		return
	var clip := _load_trimmed(path)
	DirAccess.remove_absolute(path)
	if clip == null:
		_fail("bad audio")
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
	if _ended_at > 0:
		max_gap_ms = maxi(max_gap_ms, Time.get_ticks_msec() - _ended_at)
		_ended_at = 0
	_player.play()
	_player.stream_paused = _paused


func _on_finished() -> void:
	var id := _playing_id
	_playing_id = -1
	if id != -1:
		_ended_at = Time.get_ticks_msec()
		ended.emit(id)


func _fail(why: String) -> void:
	if _broken:
		return
	push_warning("WinVoice disabled: " + why)
	_broken = true
	if not sapi_voices.is_empty():
		sapi_voices.clear()
		voices_changed.emit()
	if _pid > 0:
		OS.kill(_pid)
		_pid = -1
	failed.emit()


## Read a 16-bit PCM WAV and cut the voice's built-in silence from both ends.
static func _load_trimmed(path: String) -> AudioStreamWAV:
	var b := FileAccess.get_file_as_bytes(path)
	if b.size() < 44 or b.slice(0, 4).get_string_from_ascii() != "RIFF":
		return null
	var channels := 1
	var rate := 0
	var bits := 0
	var data := PackedByteArray()
	var i := 12
	while i + 8 <= b.size():
		var id := b.slice(i, i + 4).get_string_from_ascii()
		var size := b.decode_u32(i + 4)
		if id == "fmt ":
			if b.decode_u16(i + 8) != 1:
				return null  # not PCM
			channels = b.decode_u16(i + 10)
			rate = b.decode_u32(i + 12)
			bits = b.decode_u16(i + 22)
		elif id == "data":
			data = b.slice(i + 8, mini(i + 8 + size, b.size()))
		i += 8 + size + (size & 1)
	if bits != 16 or rate <= 0:
		return null
	if data.is_empty():
		# Nothing to say (SAPI voices render invisible text such as U+3164 to no audio).
		data.resize(2 * channels * rate / 100)  # 10 ms of silence
		data.fill(0)
	var frame := 2 * channels
	var frames := data.size() / frame
	var first := 0
	while first < frames and absi(data.decode_s16(first * frame)) < SILENCE:
		first += 1
	var last := frames - 1
	while last > first and absi(data.decode_s16(last * frame)) < SILENCE:
		last -= 1
	if first >= frames:
		first = 0
		last = 0
	first = maxi(0, first - rate * LEAD_KEEP_MS / 1000)
	last = mini(frames - 1, last + rate * TRAIL_KEEP_MS / 1000)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = channels == 2
	wav.data = data.slice(first * frame, (last + 1) * frame)
	return wav
