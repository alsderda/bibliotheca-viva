class_name SourcePlugin
extends RefCounted
## Base class for site plugins. A plugin is a folder with plugin.json and a
## script that extends this class (see PLUGINS.md). The app loads it at
## runtime, so plugins can be installed after the app is built.
##
## Every method has a safe default; a plugin overrides what its site supports.
## Results use these shapes:
##   search      -> {results: [{title, url, cover_url, info}], error, blocked}
##   fetch_novel -> {novel: {title, author, cover_url, synopsis, tags, url, chapters: [{title, url, date}], extra, words}, error, blocked, rss_only}
##                  `words` is optional: the book's length as the site reports it. Shown next to the count of the saved chapters.
##                  `extra` is optional: anything the plugin wants kept on the book (e.g. {"status": "completed"}),
##                  stored as the book's `extra` and refreshed on each check. Library filters read it.
##   fetch_chapter -> {title, paragraphs, error}   (error "blocked" for a bot check)

## The plugin's status changed (see status()).
signal status_changed

## From plugin.json.
var id := ""
var name := ""
var version := ""
var manifest := {}
## Folder the plugin was loaded from (res:// or user:// path).
var dir := ""


# --- lifecycle ---------------------------------------------------------------

## Called once after loading. Start background work here.
func setup() -> void:
	pass


## Called before the plugin is unloaded (app closing, plugin updated or removed).
func shutdown() -> void:
	pass


# --- which links belong to the plugin -----------------------------------------

## True when `url` is on one of the plugin's sites. Default: the "domains" in plugin.json.
func handles_url(url: String) -> bool:
	var host := url.get_slice("/", 2).to_lower().get_slice(":", 0)
	for d in manifest.get("domains", []):
		if host == d or host.ends_with("." + str(d)):
			return true
	return false


## Same book whatever the slug, host variant or query, e.g. "mysite:123". "" = compare plain URLs.
func book_key(_url: String) -> String:
	return ""


## Same chapter whatever the slug or query. "" = compare plain URLs.
func chapter_key(_url: String) -> String:
	return ""


# --- searching and reading -----------------------------------------------------

## What Browse lists in its source picker: [{key, label}]. `key` is passed back to search().
func search_sources() -> Array:
	if not manifest.get("search", true):
		return []
	return [{"key": "", "label": name}]


func search(_query: String, _source_key := "") -> Dictionary:
	return {"results": [], "error": "%s can't search." % name}


## The site's own search page for `query`, to open in the Web tab when the app is blocked.
func search_url(_query: String) -> String:
	return ""


func fetch_novel(_url: String) -> Dictionary:
	return {"error": "%s can't add books by link." % name}


## `book` is the library book, `chapter` its {title, url}, `index` its position.
func fetch_chapter(_book: Dictionary, _chapter: Dictionary, _index: int) -> Dictionary:
	return {"error": "%s can't download chapters." % name}


# --- library filters ---------------------------------------------------------

## Extra filters for the plugin's books on the Library page, shown once the
## plugin is picked as the source: [{key, label, options: [{key, label}]}].
## The app adds an "Any" choice to each. [] = no extra filters.
func library_filters() -> Array:
	return []


## Whether `book` passes filter `key` set to option `value`. Default: the book's
## `extra[key]` equals `value` (or contains it, for a list).
func library_filter_matches(book: Dictionary, key: String, value: String) -> bool:
	var v: Variant = book.get("extra", {}).get(key)
	if v is Array:
		return v.any(func(x): return str(x) == value)
	return v != null and str(v) == value


# --- saved searches ----------------------------------------------------------

## A page that lists works and can be saved as a search, watched for new works.
func is_listing_url(_url: String) -> bool:
	return false


## A readable name for a saved search ("hero academia", "Works in Overwatch").
func listing_name(_url: String) -> String:
	return name + " search"


## A hint shown under a saved search (e.g. to sort it by date). "" for none.
func listing_tip(_url: String) -> String:
	return ""


# --- web tab -------------------------------------------------------------------

## The site's start page, offered in the Web tab's site menu. "" to leave it out.
func home_url() -> String:
	return manifest.get("home", "")


## JavaScript that recognises the plugin's pages in the Web tab (see PLUGINS.md).
## Default: the file named by "web" in plugin.json.
func web_script() -> String:
	var file: String = manifest.get("web", "")
	if file == "" or not FileAccess.file_exists(dir.path_join(file)):
		return ""
	return FileAccess.get_file_as_string(dir.path_join(file))


# --- status, settings and UI ------------------------------------------------------

## For plugins that run a helper: {"ok": bool, "text": "Online · 40 sites", "short": "helper online"}.
## {} = nothing to show.
func status() -> Dictionary:
	return {}


## Extra controls for the plugin's card in Browse → Sources (buttons, lists).
func card_controls() -> Array:
	return []


## Rows for Settings → Plugins: [[label, hint, Control], …].
func settings_rows() -> Array:
	return []


## Plugin settings stay on this device (they're not synced).
func get_setting(key: String, default: Variant = null) -> Variant:
	return (Settings.get_value("plugin_settings") as Dictionary).get(id, {}).get(key, default)


func set_setting(key: String, value: Variant) -> void:
	var all: Dictionary = (Settings.get_value("plugin_settings") as Dictionary).duplicate(true)
	var mine: Dictionary = all.get(id, {})
	mine[key] = value
	all[id] = mine
	Settings.set_value("plugin_settings", all)


## Show a short message at the bottom of the app. kind: "info", "ok" or "error".
func notify(text: String, kind := "info") -> void:
	Plugins.message.emit(text, kind)


## Absolute path of a file in the plugin's folder, for passing to other programs.
func os_path(file: String) -> String:
	return ProjectSettings.globalize_path(dir.path_join(file))


## Checks for the self-test: call check.call(name, got, want) for each.
func run_tests(_check: Callable) -> void:
	pass


# --- helpers for site plugins ------------------------------------------------------

## A bot-check / challenge page instead of the real one.
static func is_blocked(r: Dictionary) -> bool:
	var t: String = r.get("text", "")
	if "Just a moment..." in t or "cf-challenge" in t \
			or "Attention Required! | Cloudflare" in t or "anubis_challenge" in t \
			or "Making sure you&#39;re not a bot" in t:
		return true
	return int(r.get("code", 0)) in [403, 429, 503] and "cloudflare" in t.to_lower()


## Message for a page the site wouldn't show the app.
func blocked_message() -> String:
	return "%s is showing a bot check to the app. Open it in the Web tab instead; chapters you open there are saved to your library." % name


## HTML from `start` up to the tag that closes the element opened just before it.
static func until_close(html: String, start: int, tag := "div") -> String:
	var depth := 1
	var i := start
	var re := HtmlText._re("(?i)<(/?)%s\\b" % tag)
	while depth > 0:
		var m := re.search(html, i)
		if m == null:
			return html.substr(start)
		depth += -1 if m.get_string(1) == "/" else 1
		i = m.get_end()
		if depth == 0:
			return html.substr(start, m.get_start() - start)
	return html.substr(start)


## Inner HTML of the first element whose opening tag matches `open_re` (e.g. "<div[^>]*id=\"chp_raw\"").
static func element(html: String, open_re: String, tag := "div") -> String:
	var m := HtmlText._re("(?is)" + open_re + "[^>]*>").search(html)
	if m == null:
		return ""
	return until_close(html, m.get_end(), tag)


## Plain text of an HTML snippet on one line.
static func text(html: String) -> String:
	return HtmlText._re("\\s+").sub(HtmlText.strip_tags(html), " ", true).strip_edges()


static func absolute(url: String, base: String) -> String:
	url = HtmlText.decode_entities(url.strip_edges())
	if url.begins_with("//"):
		return "https:" + url
	if url.begins_with("/"):
		return base + url
	return url


## Paragraphs with the site's leftover chrome removed.
static func paragraphs(html: String, drop_re := "") -> PackedStringArray:
	if drop_re != "":
		html = HtmlText._re("(?is)" + drop_re).sub(html, "", true)
	return HtmlText.to_paragraphs(html)


## Paragraphs of a synopsis, joined as plain text.
static func synopsis(html: String) -> String:
	return "\n\n".join(Array(HtmlText.to_paragraphs(html)).map(HtmlText.plain))


static func re(pattern: String) -> RegEx:
	return HtmlText._re(pattern)


## Wait `seconds` (to go easy on a site between requests).
static func pause(seconds: float) -> void:
	await Engine.get_main_loop().create_timer(seconds).timeout
