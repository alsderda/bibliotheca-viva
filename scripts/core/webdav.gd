class_name WebDav
extends RefCounted
## Minimal WebDAV client written directly on TCP/TLS sockets. Godot's HTTPClient
## only accepts a fixed list of methods, and WebDAV also needs PROPFIND (list a
## folder) and MKCOL (create a folder). Keeps one keep-alive connection open.
##
## Paths passed to the methods are relative to the base URL, e.g. "devices/x.json".
## Folder paths end with "/". Every call returns a Dictionary with at least
## {ok, code, error}.

const PROPFIND_BODY := """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/></d:prop></d:propfind>"""

var timeout := 30.0          ## seconds without any data before a request fails
## Shortest time between the starts of two requests. Some servers (Koofr) answer
## a fast run of requests with HTTP 429; a steady pace keeps them from doing so.
## A busy reply slows the pace for a while; it eases back with each request
## that goes through.
var min_interval := 0.0
## Waits made after the server says it's busy (429/503) before giving up.
var busy_retries := 6
## Called with the number of seconds before a wait for a busy server.
var on_busy_wait: Callable

const BUSY_WAIT_FIRST := 5.0
const BUSY_WAIT_MAX := 120.0

var _host := ""
var _port := 0
var _tls := false
var _base_path := "/"
var _auth := ""
var _url_error := ""
var _tcp: StreamPeerTCP
var _stream: StreamPeer
var _buf := PackedByteArray()
var _last_start := 0
var _slowdown := 0.0         # extra seconds between requests after busy replies


func _init(url: String, user := "", password := "") -> void:
	var m := RegEx.create_from_string("^(https?)://([^/:]+)(?::(\\d+))?(/.*)?$").search(url.strip_edges())
	if m == null:
		_url_error = "The server address should look like https://example.com/dav/"
		return
	_tls = m.get_string(1) == "https"
	_host = m.get_string(2)
	_port = m.get_string(3).to_int() if m.get_string(3) != "" else (443 if _tls else 80)
	_base_path = m.get_string(4) if m.get_string(4) != "" else "/"
	_base_path = _base_path.replace(" ", "%20")
	if not _base_path.ends_with("/"):
		_base_path += "/"
	if user != "" or password != "":
		_auth = "Basic " + Marshalls.utf8_to_base64("%s:%s" % [user, password])


func close() -> void:
	if _tcp:
		_tcp.disconnect_from_host()
	_tcp = null
	_stream = null
	_buf.clear()


# --- WebDAV verbs ------------------------------------------------------------

## -> {ok, code, error, entries: [{name, is_dir, etag, size}]}. Entries are the
## folder's direct children (not the folder itself). A missing folder gives code 404.
func list(path: String) -> Dictionary:
	var r := await request("PROPFIND", path, PROPFIND_BODY.to_utf8_buffer(), {"Depth": "1", "Content-Type": "application/xml; charset=utf-8"})
	r.entries = []
	if r.code == 207:
		r.ok = true
		r.entries = _parse_multistatus(r.body, _full_path(path))
	elif r.ok:
		r.ok = false
		r.error = "The server doesn't look like a WebDAV server (HTTP %d)" % r.code
	return r


## Creating a folder that already exists counts as success.
func make_dir(path: String) -> Dictionary:
	var r := await request("MKCOL", path)
	if r.code == 405:
		r.ok = true
		r.error = ""
	return r


func put(path: String, body: PackedByteArray, content_type := "application/octet-stream") -> Dictionary:
	return await request("PUT", path, body, {"Content-Type": content_type})


func fetch(path: String) -> Dictionary:
	return await request("GET", path)


## Deleting something that's already gone counts as success.
func remove(path: String) -> Dictionary:
	var r := await request("DELETE", path)
	if r.code == 404:
		r.ok = true
		r.error = ""
	return r


## Requests sent by all clients so far (the sync test counts them).
static var requests := 0


# --- HTTP --------------------------------------------------------------------

## -> {ok, code, body: PackedByteArray, headers: {lowercase name: value}, error}
## A server that's busy (HTTP 429 or 503) is waited for, using its Retry-After
## value when it sends one, and each wait also slows the pace for a while.
func request(method: String, path: String, body := PackedByteArray(), headers := {}) -> Dictionary:
	if _url_error != "":
		return _fail(_url_error)
	requests += 1
	var wait := BUSY_WAIT_FIRST
	for attempt in busy_retries + 1:
		await _pace()
		var r := await _request_once(method, path, body, headers)
		if not r.code in [429, 503]:
			_slowdown = maxf(_slowdown * 0.95 - 0.005, 0.0)
			return r
		if attempt == busy_retries:
			return r
		var s := retry_after_seconds(str(r.headers.get("retry-after", "")))
		s = clampf(s if s >= 0.0 else wait, 1.0, BUSY_WAIT_MAX)
		wait = minf(wait * 2.0, BUSY_WAIT_MAX)
		_slowdown = minf(_slowdown + 0.2, 1.0)
		print("WebDAV: server busy (HTTP %d) on %s %s, waiting %d s" % [r.code, method, path, ceili(s)])
		if on_busy_wait.is_valid():
			on_busy_wait.call(s)
		await (Engine.get_main_loop() as SceneTree).create_timer(s).timeout
	return _fail("Connection lost")


## Seconds from a Retry-After header (a number or an HTTP date); -1 when missing.
static func retry_after_seconds(value: String) -> float:
	value = value.strip_edges()
	if value == "":
		return -1.0
	if value.is_valid_int() or value.is_valid_float():
		return maxf(value.to_float(), 0.0)
	# e.g. "Wed, 21 Oct 2015 07:28:00 GMT"
	var m := RegEx.create_from_string("(\\d{1,2}) (\\w{3}) (\\d{4}) (\\d{2}):(\\d{2}):(\\d{2})").search(value)
	if m == null:
		return -1.0
	var month := ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].find(m.get_string(2).to_lower()) + 1
	if month == 0:
		return -1.0
	var at := Time.get_unix_time_from_datetime_dict({"year": m.get_string(3).to_int(), "month": month, "day": m.get_string(1).to_int(),
		"hour": m.get_string(4).to_int(), "minute": m.get_string(5).to_int(), "second": m.get_string(6).to_int()})
	return maxf(at - Time.get_unix_time_from_system(), 0.0)


func _pace() -> void:
	var next := _last_start + int((min_interval + _slowdown) * 1000)
	while Time.get_ticks_msec() < next:
		await _frame()
	_last_start = Time.get_ticks_msec()


func _request_once(method: String, path: String, body: PackedByteArray, headers: Dictionary) -> Dictionary:
	# A kept-alive connection may have been closed by the server in the meantime;
	# if nothing came back on a reused connection, retry once on a fresh one.
	for attempt in 2:
		var reused := _stream != null
		var err := await _connect()
		if err != "":
			return _fail(err)
		if not _send(method, path, body, headers):
			close()
			if reused and attempt == 0:
				continue
			return _fail("Connection lost while sending")
		var res := await _receive(method)
		if res.has("retry") and reused and attempt == 0:
			close()
			continue
		res.erase("retry")
		return res
	return _fail("Connection lost")


func _send(method: String, path: String, body: PackedByteArray, headers: Dictionary) -> bool:
	var lines := PackedStringArray([
		"%s %s HTTP/1.1" % [method, _full_path(path)],
		"Host: " + (_host if _port in [80, 443] else "%s:%d" % [_host, _port]),
		"User-Agent: bibliotheca-viva",
		"Content-Length: %d" % body.size(),
	])
	if _auth != "":
		lines.append("Authorization: " + _auth)
	for k in headers:
		lines.append("%s: %s" % [k, headers[k]])
	var data := ("\r\n".join(lines) + "\r\n\r\n").to_utf8_buffer()
	data.append_array(body)
	return _stream.put_data(data) == OK


func _receive(method: String) -> Dictionary:
	# headers
	var head_end := -1
	while true:
		head_end = _find_blank_line(_buf)
		if head_end >= 0:
			break
		var got := await _read_more()
		if got != "":
			close()
			return _fail(got) if _buf.size() > 0 or got == "Timed out" else {"retry": true, "ok": false, "code": 0, "error": got, "body": PackedByteArray(), "headers": {}}
	var head := _buf.slice(0, head_end).get_string_from_utf8().split("\r\n")
	_buf = _buf.slice(head_end + 4)
	var status := head[0].split(" ")
	var code := status[1].to_int() if status.size() > 1 else 0
	var hdrs := {}
	for i in range(1, head.size()):
		var c := head[i].find(":")
		if c > 0:
			hdrs[head[i].left(c).strip_edges().to_lower()] = head[i].substr(c + 1).strip_edges()
	# body
	var body := PackedByteArray()
	var keep_alive: bool = hdrs.get("connection", "").to_lower() != "close" and head[0].begins_with("HTTP/1.1")
	if method == "HEAD" or code == 204 or code == 304 or (code >= 100 and code < 200):
		pass
	elif hdrs.get("transfer-encoding", "").to_lower().contains("chunked"):
		while true:
			var line_end := _find_crlf(_buf, 0)
			while line_end < 0:
				var e := await _read_more()
				if e != "":
					close()
					return _fail(e)
				line_end = _find_crlf(_buf, 0)
			var size := _buf.slice(0, line_end).get_string_from_ascii().get_slice(";", 0).strip_edges().hex_to_int()
			_buf = _buf.slice(line_end + 2)
			if size == 0:
				# trailers end with an empty line
				while _find_crlf(_buf, 0) < 0:
					var e := await _read_more()
					if e != "":
						break
				var t := _find_blank_line_or_crlf(_buf)
				_buf = _buf.slice(t)
				break
			while _buf.size() < size + 2:
				var e := await _read_more()
				if e != "":
					close()
					return _fail(e)
			body.append_array(_buf.slice(0, size))
			_buf = _buf.slice(size + 2)
	elif hdrs.has("content-length"):
		var n := int(hdrs["content-length"])
		while _buf.size() < n:
			var e := await _read_more()
			if e != "":
				close()
				return _fail(e)
		body = _buf.slice(0, n)
		_buf = _buf.slice(n)
	else:
		# read until the server closes the connection
		while true:
			var e := await _read_more()
			if e != "":
				break
		body = _buf
		_buf = PackedByteArray()
		keep_alive = false
	if not keep_alive:
		close()
	var ok := code >= 200 and code < 300
	return {"ok": ok, "code": code, "body": body, "headers": hdrs, "error": "" if ok else _status_text(code)}


func _connect() -> String:
	if _stream != null:
		_poll()
		if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED and (not _tls or (_stream as StreamPeerTLS).get_status() == StreamPeerTLS.STATUS_CONNECTED):
			return ""
		close()
	var deadline := Time.get_ticks_msec() + int(timeout * 1000)
	_tcp = StreamPeerTCP.new()
	var ip := _host
	if not _host.is_valid_ip_address():
		ip = IP.resolve_hostname(_host)
		if ip == "":
			_tcp = null
			return "Can't find the server %s" % _host
	if _tcp.connect_to_host(ip, _port) != OK:
		_tcp = null
		return "Can't connect to %s" % _host
	while _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		_tcp.poll()
		if Time.get_ticks_msec() > deadline:
			close()
			return "Timed out connecting to %s" % _host
		await _frame()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		close()
		return "Can't connect to %s" % _host
	_tcp.set_no_delay(true)
	if not _tls:
		_stream = _tcp
		return ""
	var tls := StreamPeerTLS.new()
	if tls.connect_to_stream(_tcp, _host, TLSOptions.client()) != OK:
		close()
		return "Secure connection to %s failed" % _host
	while tls.get_status() == StreamPeerTLS.STATUS_HANDSHAKING:
		tls.poll()
		if Time.get_ticks_msec() > deadline:
			close()
			return "Timed out connecting to %s" % _host
		await _frame()
	if tls.get_status() != StreamPeerTLS.STATUS_CONNECTED:
		close()
		return "Secure connection to %s failed (certificate problem?)" % _host
	_stream = tls
	return ""


## Appends whatever has arrived to _buf. Returns "" on progress, or an error
## ("closed" when the server hung up, "Timed out" after `timeout` seconds with
## nothing arriving).
func _read_more() -> String:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000)
	while true:
		if _stream == null:
			return "closed"
		_poll()
		var n := _stream.get_available_bytes()
		if n > 0:
			var r: Array = _stream.get_partial_data(n)
			if r[0] != OK:
				return "closed"
			_buf.append_array(r[1])
			return ""
		if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return "closed"
		if _tls and (_stream as StreamPeerTLS).get_status() != StreamPeerTLS.STATUS_CONNECTED:
			return "closed"
		if Time.get_ticks_msec() > deadline:
			return "Timed out"
		await _frame()
	return "closed"


func _poll() -> void:
	if _tcp:
		_tcp.poll()
	if _tls and _stream:
		(_stream as StreamPeerTLS).poll()


func _frame() -> void:
	await (Engine.get_main_loop() as SceneTree).process_frame


func _full_path(path: String) -> String:
	var parts := PackedStringArray()
	for seg in path.split("/"):
		parts.append(seg.uri_encode())
	return _base_path + "/".join(parts)


func _fail(msg: String) -> Dictionary:
	return {"ok": false, "code": 0, "body": PackedByteArray(), "headers": {}, "error": msg}


static func _status_text(code: int) -> String:
	match code:
		401: return "Wrong username or password"
		403: return "The server refused access (HTTP 403)"
		404: return "Not found on the server (check the address)"
		405: return "The server doesn't allow this (HTTP 405)"
		409: return "The parent folder doesn't exist (HTTP 409)"
		423: return "The file is locked on the server (HTTP 423)"
		429: return "The server is limiting requests (HTTP 429). Sync tries again later."
		503: return "The server is busy or down (HTTP 503). Sync tries again later."
		507: return "The server is out of space"
	if code >= 300 and code < 400:
		return "The server redirected the request (HTTP %d). Check the address, including the trailing /." % code
	return "HTTP %d" % code


static func _find_crlf(buf: PackedByteArray, from: int) -> int:
	var i := buf.find(13, from)
	while i >= 0 and i + 1 < buf.size():
		if buf[i + 1] == 10:
			return i
		i = buf.find(13, i + 1)
	return -1


static func _find_blank_line(buf: PackedByteArray) -> int:
	var i := _find_crlf(buf, 0)
	while i >= 0 and i + 3 < buf.size():
		if buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
		i = _find_crlf(buf, i + 2)
	return -1


## After the last chunk: skip optional trailers up to and including the blank line.
static func _find_blank_line_or_crlf(buf: PackedByteArray) -> int:
	if buf.size() >= 2 and buf[0] == 13 and buf[1] == 10:
		return 2
	var i := _find_blank_line(buf)
	return i + 4 if i >= 0 else buf.size()


static func _parse_multistatus(body: PackedByteArray, self_path: String) -> Array:
	var out := []
	var xml := XMLParser.new()
	if body.is_empty() or xml.open_buffer(body) != OK:
		return out
	var cur := {}
	var tag := ""
	while xml.read() == OK:
		match xml.get_node_type():
			XMLParser.NODE_ELEMENT:
				tag = xml.get_node_name().get_slice(":", 1) if xml.get_node_name().contains(":") else xml.get_node_name()
				if tag == "response":
					cur = {"href": "", "is_dir": false, "etag": "", "size": 0}
				elif tag == "collection":
					cur.is_dir = true
			XMLParser.NODE_TEXT:
				var t := xml.get_node_data().strip_edges()
				if t != "" and not cur.is_empty():
					match tag:
						"href": cur.href += t
						"getetag": cur.etag = t
						"getcontentlength": cur.size = t.to_int()
			XMLParser.NODE_ELEMENT_END:
				var name := xml.get_node_name().get_slice(":", 1) if xml.get_node_name().contains(":") else xml.get_node_name()
				if name == "response" and not cur.is_empty():
					var href: String = cur.href
					var m := RegEx.create_from_string("^https?://[^/]+").search(href)
					if m:
						href = href.substr(m.get_end())
					if href.uri_decode().trim_suffix("/") != self_path.uri_decode().trim_suffix("/"):
						cur["name"] = href.trim_suffix("/").get_file().uri_decode()
						cur.erase("href")
						out.append(cur)
					cur = {}
				tag = ""
	return out
