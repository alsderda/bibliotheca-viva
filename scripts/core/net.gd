extends Node
## Awaitable HTTP helpers, and the fetch manager that keeps the app polite to sites.
##
## Every request waits its turn in its site's queue: one request at a time, with
## a gap after each one (1 s, or the plugin's "request_gap" in plugin.json).
## Images wait in their host's queue too, ahead of pages, so covers show up quickly
## without any host getting more than one request at a time.
## A site that answers "busy" (HTTP 429 or 503) gets a break, its full Retry-After
## or a growing wait, before anything else is sent to it, and the request is tried
## once more. While a break has more than BUSY_RETRY_MAX seconds left, requests to
## the site fail at once instead of waiting. A bot check is remembered too
## (blocked_since), so bulk work can stop asking a site that is showing one.
## A site that isn't answering (timeouts, failed connections, 5xx errors other than
## 503) gets a break too: 1 minute at first, growing slowly to an hour while it keeps
## failing. Requests to it fail at once until the break is over. An answer resets
## the break, and so does restarting the app.
## A wait a site asked for (Retry-After) still holds after a restart, until it's over,
## while "http_keep_waits" is on (the default). Turning the setting off and
## restarting clears it.
## Pages and images that came with an ETag or Last-Modified are kept (CACHE_MAX_MB of
## pages, IMAGE_CACHE_MAX_MB of images, kept apart so covers don't push out chapter
## lists), and asked for again with If-None-Match / If-Modified-Since: when the site
## answers 304 Not Modified, the kept copy is returned as if it had been downloaded.
## The "http_revalidate" setting turns this off, for sites that answer 304 wrongly.
## The same GET asked for twice at once is downloaded once.
##
## Sync doesn't come through here: WebDav paces its own requests.

const DEFAULT_GAP := 1.0
const BUSY_WAIT_FIRST := 5.0
const BUSY_WAIT_MAX := 120.0
## A busy site asking for a longer break than this fails the request instead of keeping it waiting.
const BUSY_RETRY_MAX := 60.0
## Longest Retry-After honoured, against nonsense values.
const RETRY_AFTER_MAX := 86400.0
## Breaks for a site that isn't answering: the first, how much longer each next one is, and the longest.
const DOWN_WAIT_FIRST := 60.0
const DOWN_WAIT_GROWTH := 1.5
const DOWN_WAIT_MAX := 3600.0
## Kept pages: the most kept in all, and the biggest page (or image) kept.
const CACHE_MAX_MB := 50
## Kept images (covers): the most kept in all.
const IMAGE_CACHE_MAX_MB := 30
const CACHE_PAGE_MAX_MB := 2
## Waits sites asked for, kept for the next start: {queue key: unix time the wait ends}.
const WAITS_FILE := "site_waits.json"

## Says plainly what the app is, so sites can tell it apart from a browser.
var user_agent := "bibliotheca-viva/%s" % ProjectSettings.get_setting("application/config/version", "0")

var _site_gaps := {}  # domain -> seconds between requests (from plugins)
var _lanes := {}      # queue key -> Lane
var _shared := {}     # key -> Pending
var _blocked := {}    # queue key -> msec of the last bot check seen
var _next_ticket := 0
var _cache_writes := 0


class Lane:
	var gap := DEFAULT_GAP
	var running := 0
	var next_start := 0      # msec: nothing starts before this
	var waiting: Array[int] = []      # images first, then pages, each in arrival order
	var images_waiting := 0           # how many of `waiting` (at the front) are images
	var busy_wait := BUSY_WAIT_FIRST
	var down_until := 0      # msec: the site isn't answering, nothing is sent before this
	var down_wait := DOWN_WAIT_FIRST


class Pending:
	signal done(result: Variant)
	var waiters := 0


func _ready() -> void:
	_prune_cache.call_deferred(false)
	_prune_cache.call_deferred(true)
	_restore_waits()


## Domains of the installed plugins and the gap each wants: {domain: seconds}.
func set_sites(gaps: Dictionary) -> void:
	_site_gaps = gaps


## The queue a URL waits in: its plugin's domain, or its host without "www.".
func lane_key(url: String) -> String:
	var host := url.get_slice("/", 2) if "://" in url else ""
	host = host.substr(host.rfind("@") + 1).get_slice(":", 0).to_lower()
	var site := host.trim_prefix("www.")
	var best := ""
	for d in _site_gaps:
		if (host == d or host.ends_with("." + str(d))) and str(d).length() > best.length():
			best = d
	if best != "":
		return best
	return site


## Whether `url`'s site showed the app a bot check at or after `since_msec` (Time.get_ticks_msec()).
func blocked_since(url: String, since_msec: int) -> bool:
	return int(_blocked.get(lane_key(url), -1)) >= since_msec


## Ends the break of `url`'s site for not answering, so the next request goes out
## (the user asked to try again). If it fails again, the next break is still longer.
func end_break(url: String) -> void:
	var lane: Lane = _lanes.get(lane_key(url))
	if lane:
		lane.down_until = 0


## Returns {ok, code, body: PackedByteArray, headers: PackedStringArray, error}.
## `paced` false skips the site's queue (for the app's own downloads, like plugins).
## `still_wanted`, when given, is asked before the request goes out; if it returns
## false the request is dropped and comes back with the error "Cancelled".
func request(url: String, headers: PackedStringArray = [], timeout := 30.0, method := HTTPClient.METHOD_GET, body := "",
		paced := true, still_wanted := Callable(), image := false) -> Dictionary:
	if method != HTTPClient.METHOD_GET or body != "":
		return await _request_paced(url, headers, timeout, method, body, paced, still_wanted, image)
	var key := "get\n%s\n%s" % [url, "\n".join(headers)]
	return await shared(key, func(): return await _request_paced(url, headers, timeout, method, body, paced, still_wanted, image))


## Runs `job` (an awaitable Callable) once for everyone asking with the same key at the
## same time; they all get its result.
func shared(key: String, job: Callable) -> Variant:
	if _shared.has(key):
		var p: Pending = _shared[key]
		p.waiters += 1
		var r: Variant = await p.done
		return r.duplicate(true) if r is Dictionary else r
	var mine := Pending.new()
	_shared[key] = mine
	var result: Variant = await job.call()
	_shared.erase(key)
	mine.done.emit(result)
	return result


## Whether anyone besides the first caller is waiting for this GET.
func _has_waiters(url: String, headers: PackedStringArray) -> bool:
	var p: Pending = _shared.get("get\n%s\n%s" % [url, "\n".join(headers)])
	return p != null and p.waiters > 0


func _request_paced(url: String, headers: PackedStringArray, timeout: float, method: int, body: String,
		paced: bool, still_wanted: Callable, image: bool) -> Dictionary:
	var wanted := func() -> bool:
		return not still_wanted.is_valid() or still_wanted.call() or _has_waiters(url, headers)
	if not paced:
		return await _send(url, headers, timeout, method, body)
	var key := lane_key(url)
	var cache := ""
	var send_headers := headers
	if method == HTTPClient.METHOD_GET and body == "" and Settings.get_value("http_revalidate"):
		cache = _cache_path(url, headers, image)
		send_headers = headers + conditional_headers(_cache_meta(cache))
	var retried := false
	while true:
		var lane := _lane(key)
		var turn := await _take_turn(lane, wanted, image)
		if turn == TURN_CANCELLED:
			return {"ok": false, "code": 0, "body": PackedByteArray(), "headers": PackedStringArray(), "error": "Cancelled"}
		if turn == TURN_PAUSED:
			var mins := ceili((lane.next_start - Time.get_ticks_msec()) / 60000.0)
			return {"ok": false, "code": 429, "body": PackedByteArray(), "headers": PackedStringArray(),
				"error": "%s asked the app to wait. Try again in %d minute(s)." % [key, mins]}
		if turn == TURN_DOWN:
			var mins := ceili((lane.down_until - Time.get_ticks_msec()) / 60000.0)
			return {"ok": false, "code": 0, "body": PackedByteArray(), "headers": PackedStringArray(),
				"error": "%s isn't answering. The app will try it again in %d minute(s)." % [key, mins]}
		var r := await _send(url, send_headers, timeout, method, body)
		_release(lane)
		var blocked := SourcePlugin.is_blocked(r_text(r))
		if blocked:
			_blocked[key] = Time.get_ticks_msec()
		if not blocked and site_down(r):
			lane.down_until = Time.get_ticks_msec() + int(lane.down_wait * 1000)
			print("Net: %s isn't answering (%s), waiting %d s before the next request" % [key, r.error, ceili(lane.down_wait)])
			lane.down_wait = minf(lane.down_wait * DOWN_WAIT_GROWTH, DOWN_WAIT_MAX)
			return r
		if r.code > 0:
			lane.down_wait = DOWN_WAIT_FIRST
		if cache != "" and not blocked:
			r = _use_cache(cache, url, r)
		if not r.code in [429, 503] or blocked:
			lane.busy_wait = BUSY_WAIT_FIRST
			return r
		# The site says it's busy: no one sends it anything until the break is over.
		var s := WebDav.retry_after_seconds(header(r.headers, "retry-after"))
		var asked := s >= 0.0
		s = clampf(s, 1.0, RETRY_AFTER_MAX) if asked else lane.busy_wait
		lane.busy_wait = minf(lane.busy_wait * 2.0, BUSY_WAIT_MAX)
		lane.next_start = maxi(lane.next_start, Time.get_ticks_msec() + int(s * 1000))
		if asked:
			_keep_wait(key, s)
		print("Net: %s is busy (HTTP %d), waiting %d s before the next request" % [key, r.code, ceili(s)])
		if retried or s > BUSY_RETRY_MAX:
			return r
		retried = true
	return {}


func _lane(key: String) -> Lane:
	var lane: Lane = _lanes.get(key)
	if lane == null:
		lane = Lane.new()
		_lanes[key] = lane
	lane.gap = float(_site_gaps.get(key, DEFAULT_GAP))
	return lane


enum { TURN_OK, TURN_CANCELLED, TURN_PAUSED, TURN_DOWN }


## Whether a reply means the site isn't answering: a timeout, a failed connection, or
## a server error. 503 is left to the busy handling; a failed DNS lookup is more
## likely this device being offline.
static func site_down(r: Dictionary) -> bool:
	if r.get("result", HTTPRequest.RESULT_SUCCESS) in [HTTPRequest.RESULT_CANT_CONNECT,
			HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_TIMEOUT]:
		return true
	var code := int(r.get("code", 0))
	return code >= 500 and code < 600 and code != 503


## Waits until it's this request's turn in the lane. Images go ahead of pages waiting there.
## TURN_CANCELLED if it was no longer wanted, TURN_PAUSED if the site asked for a long break,
## TURN_DOWN if the site is on a break for not answering.
func _take_turn(lane: Lane, wanted: Callable, image: bool) -> int:
	_next_ticket += 1
	var ticket := _next_ticket
	if image:
		lane.waiting.insert(lane.images_waiting, ticket)
		lane.images_waiting += 1
	else:
		lane.waiting.append(ticket)
	var leave := func(result: int) -> int:
		if image:
			lane.images_waiting -= 1
		lane.waiting.erase(ticket)
		return result
	while lane.waiting[0] != ticket or lane.running > 0 or Time.get_ticks_msec() < lane.next_start:
		if Time.get_ticks_msec() < lane.down_until:
			return leave.call(TURN_DOWN)
		if not wanted.call():
			return leave.call(TURN_CANCELLED)
		if lane.next_start - Time.get_ticks_msec() > int(BUSY_RETRY_MAX * 1000):
			return leave.call(TURN_PAUSED)
		await get_tree().process_frame
	if Time.get_ticks_msec() < lane.down_until:
		return leave.call(TURN_DOWN)
	if not wanted.call():
		return leave.call(TURN_CANCELLED)
	leave.call(TURN_OK)
	lane.running += 1
	lane.next_start = Time.get_ticks_msec() + int(lane.gap * 1000)
	return TURN_OK


func _release(lane: Lane) -> void:
	lane.running -= 1
	lane.next_start = maxi(lane.next_start, Time.get_ticks_msec() + int(lane.gap * 1000))


func _send(url: String, headers: PackedStringArray, timeout: float, method: int, body: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout
	http.max_redirects = 8
	add_child(http)
	var all_headers := PackedStringArray(["User-Agent: " + user_agent, "Accept-Language: en-US,en;q=0.8"])
	all_headers.append_array(headers)
	var err := http.request(url, all_headers, method, body)
	if err != OK:
		http.queue_free()
		return {"ok": false, "code": 0, "body": PackedByteArray(), "headers": PackedStringArray(), "error": "Could not start request (%s)" % error_string(err)}
	var res: Array = await http.request_completed
	http.queue_free()
	var result: int = res[0]
	var code: int = res[1]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": code, "body": res[3], "headers": res[2], "error": _result_text(result), "result": result}
	return {"ok": code >= 200 and code < 300, "code": code, "body": res[3], "headers": res[2], "error": "" if code < 300 else "HTTP %d" % code}


# --- waits kept for the next start ------------------------------------------------

func _waits_path() -> String:
	return Settings.data_dir() + "/" + WAITS_FILE


func _read_waits() -> Dictionary:
	if not FileAccess.file_exists(_waits_path()):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(_waits_path()))
	return d if d is Dictionary else {}


## Saves a wait a site asked for, when "http_keep_waits" is on.
func _keep_wait(key: String, seconds: float) -> void:
	if not Settings.get_value("http_keep_waits"):
		return
	var now := Time.get_unix_time_from_system()
	var saved := _read_waits()
	var waits := {}
	for k in saved:  # drop the ones that are over
		if float(saved[k]) > now:
			waits[k] = saved[k]
	waits[key] = maxf(float(waits.get(key, 0.0)), now + seconds)
	var f := FileAccess.open(_waits_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(waits))


## At start: puts back the waits that aren't over yet, or forgets them if the setting is off.
func _restore_waits() -> void:
	var waits := _read_waits()
	if waits.is_empty():
		return
	if not Settings.get_value("http_keep_waits"):
		DirAccess.remove_absolute(_waits_path())
		return
	var now := Time.get_unix_time_from_system()
	for key in waits:
		var left := float(waits[key]) - now
		if left > 0.0:
			var lane := _lane(str(key))
			lane.next_start = maxi(lane.next_start, Time.get_ticks_msec() + int(minf(left, RETRY_AFTER_MAX) * 1000))
			print("Net: %s asked the app to wait before it closed, waiting %d s more" % [key, ceili(left)])


# --- kept pages (conditional requests) -------------------------------------------

func _cache_dir(image := false) -> String:
	return Settings.data_dir() + ("/http_cache/images" if image else "/http_cache")


func _cache_path(url: String, headers: PackedStringArray, image := false) -> String:
	return "%s/%s" % [_cache_dir(image), ("%s\n%s" % [url, "\n".join(headers)]).sha256_text()]


## What was kept for a page: {etag, last_modified, headers}, or {} if nothing.
func _cache_meta(path: String) -> Dictionary:
	if not FileAccess.file_exists(path + ".json") or not FileAccess.file_exists(path + ".bin"):
		return {}
	var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(path + ".json"))
	return m if m is Dictionary else {}


## The If-None-Match / If-Modified-Since headers for a kept page.
static func conditional_headers(meta: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if str(meta.get("etag", "")) != "":
		out.append("If-None-Match: " + str(meta.etag))
	if str(meta.get("last_modified", "")) != "":
		out.append("If-Modified-Since: " + str(meta.last_modified))
	return out


## A 304 becomes the kept page; a fresh page that can be asked about later is kept.
func _use_cache(path: String, url: String, r: Dictionary) -> Dictionary:
	if r.code == 304:
		var meta := _cache_meta(path)
		if meta.is_empty():
			return r
		var bytes := FileAccess.get_file_as_bytes(path + ".bin")
		var f := FileAccess.open(path + ".json", FileAccess.READ_WRITE)  # touch it, so it's kept longest
		if f:
			f.store_string(JSON.stringify(meta))
		return {"ok": true, "code": 200, "body": bytes, "headers": PackedStringArray(meta.get("headers", [])), "error": "", "not_modified": true}
	if r.code != 200:
		return r
	var etag := header(r.headers, "etag")
	var modified := header(r.headers, "last-modified")
	var no_store := "no-store" in header(r.headers, "cache-control").to_lower()
	if (etag == "" and modified == "") or no_store or (r.body as PackedByteArray).size() > CACHE_PAGE_MAX_MB * 1048576:
		if FileAccess.file_exists(path + ".json"):
			DirAccess.remove_absolute(path + ".json")
			DirAccess.remove_absolute(path + ".bin")
		return r
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var b := FileAccess.open(path + ".bin", FileAccess.WRITE)
	var j := FileAccess.open(path + ".json", FileAccess.WRITE)
	if b and j:
		b.store_buffer(r.body)
		j.store_string(JSON.stringify({"url": url, "etag": etag, "last_modified": modified, "headers": Array(r.headers)}))
	_cache_writes += 1
	if _cache_writes % 50 == 0:
		_prune_cache(false)
		_prune_cache(true)
	return r


## Drops the pages (or images) used longest ago until the kept ones fit in
## CACHE_MAX_MB (or IMAGE_CACHE_MAX_MB).
func _prune_cache(image: bool) -> void:
	var dir := _cache_dir(image)
	var max_bytes := (IMAGE_CACHE_MAX_MB if image else CACHE_MAX_MB) * 1048576
	if not DirAccess.dir_exists_absolute(dir):
		return
	var files := []
	var total := 0
	for name in DirAccess.get_files_at(dir):
		if not name.ends_with(".bin"):
			continue
		var base := dir + "/" + name.trim_suffix(".bin")
		var f := FileAccess.open(base + ".bin", FileAccess.READ)
		var size := f.get_length() if f else 0
		total += size
		files.append([FileAccess.get_modified_time(base + ".json"), size, base])
	if total <= max_bytes:
		return
	files.sort_custom(func(a, b): return a[0] < b[0])
	for f in files:
		if total <= max_bytes:
			break
		DirAccess.remove_absolute(f[2] + ".bin")
		DirAccess.remove_absolute(f[2] + ".json")
		total -= f[1]


## A response header's value ("" when missing).
static func header(headers: PackedStringArray, name: String) -> String:
	for h in headers:
		if h.get_slice(":", 0).strip_edges().to_lower() == name:
			return h.substr(h.find(":") + 1).strip_edges()
	return ""


static func r_text(r: Dictionary) -> Dictionary:
	return {"code": r.code, "text": (r.body as PackedByteArray).get_string_from_utf8()}


func get_text(url: String, headers: PackedStringArray = [], timeout := 30.0, paced := true) -> Dictionary:
	var r := await request(url, headers, timeout, HTTPClient.METHOD_GET, "", paced)
	r.text = (r.body as PackedByteArray).get_string_from_utf8()
	return r


## POST url-encoded form fields; returns like get_text.
func post_form(url: String, fields: Dictionary, timeout := 30.0) -> Dictionary:
	var body := "&".join(fields.keys().map(func(k): return str(k).uri_encode() + "=" + str(fields[k]).uri_encode()))
	var r := await request(url, ["Content-Type: application/x-www-form-urlencoded"], timeout, HTTPClient.METHOD_POST, body)
	r.text = (r.body as PackedByteArray).get_string_from_utf8()
	return r


func get_json(url: String, timeout := 30.0, paced := true) -> Dictionary:
	var r := await get_text(url, ["Accept: application/json"], timeout, paced)
	r.data = JSON.parse_string(r.text) if r.text != "" else null
	return r


## `still_wanted`: see request(). Covers of search results that are gone aren't downloaded.
func get_image(url: String, still_wanted := Callable()) -> Image:
	if url == "":
		return null
	var r := await request(url, ["Accept: image/*"], 20.0, HTTPClient.METHOD_GET, "", true, still_wanted, true)
	if not r.ok:
		return null
	return image_from_bytes(r.body)


static func image_from_bytes(bytes: PackedByteArray) -> Image:
	if bytes.size() < 8:
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = img.load_webp_from_buffer(bytes)
	elif bytes[0] == 0x47 and bytes[1] == 0x49:
		return null  # GIF is not supported by Image
	return img if err == OK else null


func _result_text(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT: return "Can't connect"
		HTTPRequest.RESULT_CANT_RESOLVE: return "Can't resolve host"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "Connection error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "TLS handshake error"
		HTTPRequest.RESULT_TIMEOUT: return "Timed out"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: return "Too many redirects"
	return "Request failed (%d)" % result
