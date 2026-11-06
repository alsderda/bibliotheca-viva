class_name SiteRules
## The user's own rules for reading a site in the Web tab: where the chapter
## text is, what inside it to skip, the next/previous links and the chapter
## title, each as a CSS selector. They work on any site, with or without a
## plugin, and win over what a plugin finds.
##
## Kept in the "site_rules" setting, so Sync carries them to other devices.
## Rule dictionary:
##   id, host, content, skip, next, prev, title
## `host` matches that host and its subdomains ("example.com" covers
## "www.example.com"); when several match, the longest host wins.

const FIELDS := ["content", "skip", "next", "prev", "title"]


static func all() -> Array:
	return Settings.get_value("site_rules")


static func new_rule(host := "") -> Dictionary:
	var r := {"id": "%x%04x" % [int(Time.get_unix_time_from_system()), randi() % 0xffff], "host": host}
	for f in FIELDS:
		r[f] = ""
	return r


## The site part of a link or address, without "www.".
static func host_of(url: String) -> String:
	var h := url.strip_edges().to_lower()
	if h.contains("://"):
		h = h.get_slice("://", 1)
	h = h.get_slice("/", 0).get_slice("?", 0).get_slice("#", 0)
	h = h.get_slice("@", h.get_slice_count("@") - 1).get_slice(":", 0)
	return h.trim_prefix("www.")


static func matches(rule_host: String, host: String) -> bool:
	return rule_host != "" and (host == rule_host or host.ends_with("." + rule_host))


## The rule for a page's host, or {} when there is none.
static func for_host(host: String) -> Dictionary:
	host = host_of(host)
	var best := {}
	for r in all():
		if matches(r.host, host) and (best.is_empty() or r.host.length() > best.host.length()):
			best = r
	return best


static func save(rule: Dictionary) -> void:
	var r := rule.duplicate()
	r.host = host_of(r.host)
	for f in FIELDS:
		r[f] = str(r.get(f, "")).strip_edges()
	var list := all().filter(func(x): return x.id != r.id and x.host != r.host)
	list.append(r)
	list.sort_custom(func(a, b): return a.host < b.host)
	Settings.set_value("site_rules", list)


static func remove(id: String) -> void:
	Settings.set_value("site_rules", all().filter(func(x): return x.id != id))


## What's wrong with a rule, or "" when it can be saved.
static func validate(rule: Dictionary) -> String:
	var host := host_of(rule.get("host", ""))
	if host == "" or not host.contains(".") or host.contains(" "):
		return "Enter the site's address, e.g. example.com."
	if FIELDS.all(func(f): return str(rule.get(f, "")).strip_edges() == ""):
		return "Fill in at least one selector."
	return ""
