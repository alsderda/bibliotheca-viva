extends Node
## Dev check for installing plugins from a link, and for each plugin working
## against its live site:
##   godot --path . -- --profile=plugintest --plugintest=<link to a plugin repository> [--live]
## Installs everything the repository lists, checks each plugin then runs from the
## data folder, removes them again, and with --live searches each site and opens
## the first result and its first chapter.

var failures := 0


func _ready() -> void:
	var url := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--plugintest="):
			url = a.substr(13)
	await get_tree().process_frame
	var repo: Dictionary = await Plugins.resolve(url)
	check("repository lists plugins", repo.get("plugins", []).size() > 0, true)
	for item in repo.get("plugins", []):
		var r: Dictionary = await Plugins.install_listed(item)
		check("install " + item.id, r.get("error", ""), "")
		var e := Plugins.get_entry(item.id)
		check(item.id + " runs from the data folder", [e.get("origin"), e.get("plugin") != null], ["installed", true])
	if "--live" in OS.get_cmdline_user_args():
		for p in Plugins.plugins:
			await _live(p)
	for item in repo.get("plugins", []):
		Plugins.remove(item.id)
		check("remove " + item.id, Plugins.is_installed(item.id), false)
	print("PLUGINTEST ", "PASSED" if failures == 0 else "FAILED (%d)" % failures)
	get_tree().quit(failures)


func _live(p: SourcePlugin) -> void:
	if p.search_sources().is_empty():
		return
	var r: Dictionary = await p.search("the")
	print("  live %s: search -> %d results %s" % [p.id, r.get("results", []).size(), r.get("error", "")])
	if r.get("results", []).is_empty():
		return
	var n: Dictionary = await p.fetch_novel(r.results[0].url)
	if n.get("error", "") != "":
		print("  live %s: book -> %s" % [p.id, n.error])
		return
	print("  live %s: book -> “%s”, %d chapters" % [p.id, n.novel.title, n.novel.chapters.size()])
	var c: Dictionary = await p.fetch_chapter({"url": n.novel.url}, n.novel.chapters[0], 0)
	print("  live %s: chapter 1 -> %s" % [p.id, ("%d paragraphs" % c.paragraphs.size()) if c.get("error", "") == "" else c.error])


func check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok   ", name)
	else:
		failures += 1
		print("  FAIL ", name, "\n       got:  ", got, "\n       want: ", want)
