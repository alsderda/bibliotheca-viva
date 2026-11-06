extends Node
## User replacement rules (plain text or regex) applied to chapter text.
##
## Each rule has a scope:
##   "display" - changes what you see, not what is read aloud
##   "tts"     - changes what is read aloud (pronunciation fixes, skipping noise)
##   "both"    - changes both
## and can apply to every book or to a single book.
##
## Rule dictionary:
##   id, name, enabled, pattern, replace, regex (bool), ignore_case (bool),
##   whole_word (bool), scope ("display" | "tts" | "both"), book ("" = all books)

signal changed

const SCOPES := ["both", "display", "tts"]
const SCOPE_NAMES := {"both": "Text and speech", "display": "Text only", "tts": "Speech only"}

## Ready-made rules users can add with one click.
const EXAMPLES := [
	{"name": "Don't read [bracketed] system notices aloud", "pattern": "\\[[^\\]]{1,200}\\]", "replace": " ", "regex": true, "scope": "tts"},
	{"name": "Skip scene-break lines (* * *, ~~~, ---)", "pattern": "^\\s*([*~#=_\\-•·]\\s*){3,}$", "replace": "", "regex": true, "scope": "tts"},
	{"name": "Read “HP” as “health points”", "pattern": "HP", "replace": "health points", "regex": false, "whole_word": true, "scope": "tts"},
	{"name": "Pause on em dashes", "pattern": "\\s*—\\s*", "replace": ", ", "regex": true, "scope": "tts"},
	{"name": "Remove “Translator’s note” lines", "pattern": "^\\s*\\(?(TL|T/N|Translator['’]?s? ?note)[:\\s].*$", "replace": "", "regex": true, "ignore_case": true, "scope": "both"},
	{"name": "Hide “Support me on Patreon” lines", "pattern": "^.*patreon\\.com.*$", "replace": "", "regex": true, "ignore_case": true, "scope": "both"},
]

# Private-use markers that stand in for [i] [/i] [b] [/b] while rules run,
# so patterns see normal text (including real [ and ] characters).
const I_OPEN := "\ue000"
const I_CLOSE := "\ue001"
const B_OPEN := "\ue002"
const B_CLOSE := "\ue003"

var rules: Array = []
## Unix time of the last change to the rule list (used by Sync).
var modified := 0.0
var _compiled := {}   # id -> RegEx (or null when invalid)


func _ready() -> void:
	_load()


func _path() -> String:
	return Settings.data_dir() + "/text_rules.json"


# --- editing -----------------------------------------------------------------

func new_rule(fields := {}) -> Dictionary:
	var r := {"id": "%x%04x" % [int(Time.get_unix_time_from_system()), randi() % 0xffff], "name": "", "enabled": true,
		"pattern": "", "replace": "", "regex": false, "ignore_case": false, "whole_word": false, "scope": "tts", "book": ""}
	r.merge(fields, true)
	return r


func add_rule(rule: Dictionary) -> void:
	rules.append(rule)
	_commit()


func update_rule(rule: Dictionary) -> void:
	for i in rules.size():
		if rules[i].id == rule.id:
			rules[i] = rule
			_commit()
			return
	add_rule(rule)


func remove_rule(id: String) -> void:
	rules = rules.filter(func(r): return r.id != id)
	_commit()


func move_rule(id: String, delta: int) -> void:
	for i in rules.size():
		if rules[i].id == id:
			var j := clampi(i + delta, 0, rules.size() - 1)
			var r = rules[i]
			rules.remove_at(i)
			rules.insert(j, r)
			_commit()
			return


func set_enabled(id: String, on: bool) -> void:
	for r in rules:
		if r.id == id:
			r.enabled = on
	_commit()


func export_json() -> String:
	return JSON.stringify(rules.map(func(r):
		var c: Dictionary = r.duplicate()
		c.erase("id")
		return c), "  ")


## Returns the number of rules imported, or -1 when the text isn't valid.
func import_json(text: String) -> int:
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		parsed = [parsed]
	if not (parsed is Array):
		return -1
	var n := 0
	for item in parsed:
		if item is Dictionary and str(item.get("pattern", "")) != "":
			rules.append(new_rule(item))
			n += 1
	_commit()
	return n


# --- applying ----------------------------------------------------------------

## Error message for a rule's pattern, or "" when it compiles.
func validate(rule: Dictionary) -> String:
	if str(rule.get("pattern", "")) == "":
		return "Pattern is empty"
	var re := RegEx.new()
	var err := re.compile(_source(rule), false)
	return "" if err == OK else "Invalid regular expression"


func rule_count_for(book_id: String) -> int:
	return rules.filter(func(r): return r.enabled and (r.book == "" or r.book == book_id)).size()


## Apply display rules to a reader paragraph (BBCode-safe string with [i]/[b]/[lb]/[rb]).
func apply_display(paragraph: String, book_id := "") -> String:
	if not _has_rules("display", book_id):
		return paragraph
	var raw := paragraph.replace("[i]", I_OPEN).replace("[/i]", I_CLOSE).replace("[b]", B_OPEN).replace("[/b]", B_CLOSE)
	raw = raw.replace("[lb]", "[").replace("[rb]", "]")
	raw = apply(raw, "display", book_id)
	raw = raw.replace("[", "\u0002").replace("]", "[rb]").replace("\u0002", "[lb]")
	raw = raw.replace(I_OPEN, "[i]").replace(I_CLOSE, "[/i]").replace(B_OPEN, "[b]").replace(B_CLOSE, "[/b]")
	return HtmlText._balance(raw)


## Apply speech rules to plain text.
func apply_tts(text: String, book_id := "") -> String:
	return apply(text, "tts", book_id)


## Apply every enabled rule whose scope includes `target` ("display" or "tts").
func apply(text: String, target: String, book_id := "") -> String:
	for r in rules:
		if not r.enabled or (r.scope != "both" and r.scope != target):
			continue
		if r.book != "" and r.book != book_id:
			continue
		var re := _regex(r)
		if re == null:
			continue
		text = re.sub(text, _replacement(r), true)
	return text


## Preview: {display, tts, error} for a sample string using one rule (or all rules when rule is empty).
func preview(sample: String, rule := {}, book_id := "") -> Dictionary:
	if rule.is_empty():
		return {"display": HtmlText.plain(apply_display(sample, book_id)), "tts": apply_tts(sample, book_id), "error": ""}
	var err := validate(rule)
	if err != "":
		return {"display": sample, "tts": sample, "error": err}
	var re := RegEx.new()
	re.compile(_source(rule), false)
	var out: String = re.sub(sample, _replacement(rule), true)
	var matches := re.search_all(sample).size()
	return {
		"display": out if rule.scope != "tts" else sample,
		"tts": out if rule.scope != "display" else sample,
		"error": "", "matches": matches,
	}


func _has_rules(target: String, book_id: String) -> bool:
	for r in rules:
		if r.enabled and (r.scope == "both" or r.scope == target) and (r.book == "" or r.book == book_id):
			return true
	return false


func _regex(r: Dictionary) -> RegEx:
	if _compiled.has(r.id):
		return _compiled[r.id]
	var re := RegEx.new()
	var ok := re.compile(_source(r), false) == OK
	_compiled[r.id] = re if ok else null
	return _compiled[r.id]


func _source(r: Dictionary) -> String:
	var p: String = r.pattern if r.get("regex", false) else _escape(r.pattern)
	if r.get("whole_word", false):
		p = "\\b(?:%s)\\b" % p
	# (?m) lets ^ and $ match per line; paragraphs are single lines anyway.
	return ("(?mi)" if r.get("ignore_case", false) else "(?m)") + p


func _replacement(r: Dictionary) -> String:
	var rep: String = r.get("replace", "")
	if not r.get("regex", false):
		rep = rep.replace("$", "$$")
	return rep


static func _escape(s: String) -> String:
	var out := ""
	for ch in s:
		if "\\^$.|?*+()[]{}/".contains(ch):
			out += "\\"
		out += ch
	return out


## Used by Sync: replace the rule list with one changed on another device.
func apply_synced(list: Array, stamp: float) -> void:
	rules = []
	for r in list:
		if r is Dictionary:
			rules.append(new_rule(r))
	_write(stamp)


func _commit() -> void:
	_write(Time.get_unix_time_from_system())


func _write(stamp: float) -> void:
	modified = stamp
	_compiled.clear()
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"version": 1, "modified": modified, "rules": rules}, "\t"))
	changed.emit()


func _load() -> void:
	if not FileAccess.file_exists(_path()):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path()))
	if parsed is Dictionary and parsed.get("rules") is Array:
		for r in parsed.rules:
			if r is Dictionary:
				rules.append(new_rule(r))
		modified = parsed.get("modified", FileAccess.get_modified_time(_path()) if not rules.is_empty() else 0.0)
