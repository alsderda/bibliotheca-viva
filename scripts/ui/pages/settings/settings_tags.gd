class_name SettingsTags
extends SettingsSection
## The Tags tab of Settings: groups of tags that are treated as one (aliases).


var _alias_drafts: Array = []  # blank tag rows not saved yet (see build)


var _alias_rows: Array = []  # [main tag edit, aliases edit] per row, while the Tags tab is built


func build() -> void:
	_alias_rows = []
	var intro := UI.vbox(10)
	intro.add_child(UI.label("Tag aliases", "H3"))
	intro.add_child(UI.label("Group tags that mean the same thing. The Tag filter in the library shows only the main tag, and picking it shows books with the main tag or any of its aliases. Books keep their own tags.", "Muted", true))
	var add := UI.button("New group", "plus", "PrimaryButton", func(): _new_alias_group())
	add.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	intro.add_child(add)
	_content.add_child(UI.panel("Card", intro))
	var groups := BookTags.clean_aliases(Settings.get_value("tag_aliases"))
	var list := UI.vbox(4)
	for i in groups.size():
		var g: Dictionary = groups[i]
		list.add_child(_alias_row(str(g.get("tag", "")), _aliases_text(g.get("aliases", [])), false, i))
	for d in _alias_drafts.size():
		var draft: Dictionary = _alias_drafts[d]
		list.add_child(_alias_row(str(draft.get("tag", "")), str(draft.get("aliases", "")), true, d))
	if list.get_child_count() > 0:
		_content.add_child(UI.panel("Card", list))
	else:
		_content.add_child(UI.margin(UI.label("No groups yet.", "Muted"), 6, 10, 0, 0))
	var left := _ungrouped_tags()
	if not left.is_empty():
		var shown := left.slice(0, 20)
		var s := ", ".join(PackedStringArray(shown))
		if left.size() > shown.size():
			s += " and %d more" % (left.size() - shown.size())
		_content.add_child(UI.margin(UI.label("Tags in your library not in a group: " + s, "Muted", true), 6, 0, 0, 0))


## One alias group: a main tag and its aliases as comma-separated text, each
## with tag chips under it while it has focus.
func _alias_row(tag_text: String, alias_text: String, is_draft: bool, index: int) -> Control:
	var tag := _line_edit(tag_text, 200)
	tag.placeholder_text = "Main tag, e.g. Water"
	tag.size_flags_horizontal = Control.SIZE_EXPAND_FILL if page.compact else Control.SIZE_FILL
	var alias := _line_edit(alias_text, 280)
	alias.placeholder_text = "Aliases, comma-separated, e.g. Hot water, Cold water"
	alias.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag.text_submitted.connect(func(_t): _save_aliases())
	alias.text_submitted.connect(func(_t): _save_aliases())
	tag.focus_exited.connect(_save_aliases)
	alias.focus_exited.connect(_save_aliases)
	if is_draft:
		# Unsaved typing survives a rebuild from elsewhere (see _save_aliases).
		tag.text_changed.connect(func(t): (_alias_drafts[index] as Dictionary).tag = t)
		alias.text_changed.connect(func(t): (_alias_drafts[index] as Dictionary).aliases = t)
	_alias_rows.append([tag, alias])
	var tag_suggest := TagSuggest.attach(tag, func(): return [BookTags.book_tags(), _alias_skip(tag, false)], true)
	tag_suggest.only_while_focused = true
	tag_suggest.completed.connect(func(_t): _save_aliases())
	var alias_suggest := TagSuggest.attach(alias, func(): return [BookTags.book_tags(), _alias_skip(alias, true)])
	alias_suggest.only_while_focused = true
	alias_suggest.completed.connect(func(_t): _save_aliases())
	var delete := UI.icon_button("trash", "Delete", func(): _delete_alias(index, is_draft))
	if page.compact:
		var tools := UI.hbox(2, [delete])
		tools.alignment = BoxContainer.ALIGNMENT_END
		return UI.panel("Row", UI.vbox(8, [tag, tag_suggest, alias, alias_suggest, tools]))
	var tag_box := UI.vbox(4, [tag, tag_suggest])
	var alias_box := UI.vbox(4, [alias, alias_suggest])
	alias_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	delete.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return UI.panel("Row", UI.hbox(12, [tag_box, alias_box, delete]))


## Tags a completion must not offer for `edit`: every tag used in other rows,
## plus this row's own main tag for the aliases field.
func _alias_skip(edit: LineEdit, include_own_main: bool) -> Array:
	var own := -1
	for i in _alias_rows.size():
		if (_alias_rows[i] as Array).has(edit):
			own = i
			break
	var skip := []
	for i in _alias_rows.size():
		var row: Array = _alias_rows[i]
		for c in row.size():
			if i == own and (not include_own_main or c > 0):
				continue
			skip.append_array(BookTags.clean_tags(Array(str((row[c] as LineEdit).text).split(","))))
	return skip


## Adds a blank row; it stays until it is saved with a main tag or deleted.
func _new_alias_group() -> void:
	_alias_drafts.append({"tag": "", "aliases": ""})
	await page.rebuild_keep_scroll()
	if not _alias_rows.is_empty() and is_instance_valid(_alias_rows.back()[0]):
		(_alias_rows.back()[0] as LineEdit).grab_focus()


## Saves every row through BookTags.clean_aliases. Typing alone never rebuilds:
## set_value only notifies when the cleaned groups actually changed.
## Deferred so that, when Tab moved focus to another field, the rebuilt rows
## can give focus back to the same field.
func _save_aliases() -> void:
	_save_aliases_now.call_deferred()


func _save_aliases_now() -> void:
	if _alias_rows.is_empty() or not is_instance_valid(_alias_rows[0][0]):
		return
	var focused := page.get_viewport().gui_get_focus_owner()
	var focus_at := Vector2i(-1, -1)
	for i in _alias_rows.size():
		var col: int = (_alias_rows[i] as Array).find(focused)
		if col >= 0:
			focus_at = Vector2i(i, col)
	var groups := []
	for r in _alias_rows:
		groups.append({"tag": (r[0] as LineEdit).text, "aliases": (r[1] as LineEdit).text})
	var cleaned: Array = BookTags.clean_aliases(groups)
	var kept := []
	var first_draft := _alias_rows.size() - _alias_drafts.size()
	for i in _alias_drafts.size():
		var edits: Array = _alias_rows[first_draft + i]
		if (edits[0] as LineEdit).text.strip_edges() == "":
			kept.append({"tag": (edits[0] as LineEdit).text, "aliases": (edits[1] as LineEdit).text})
	var dropped := _aliases_dropped(groups, cleaned)
	if dropped:
		page.main.toast("Some tags were already in another group, so they were left out", "warn")
	var had_drafts := _alias_drafts.size()
	var stored_before: Variant = Settings.get_value("tag_aliases")
	_alias_drafts = kept
	Settings.set_value("tag_aliases", cleaned)
	if (dropped or kept.size() != had_drafts) and JSON.stringify(Settings.get_value("tag_aliases")) == JSON.stringify(stored_before):
		page.rebuild_keep_scroll()
	if focus_at.x >= 0 and focus_at.x < _alias_rows.size() and _alias_rows[focus_at.x][focus_at.y] != focused:
		var edit: LineEdit = _alias_rows[focus_at.x][focus_at.y]
		edit.grab_focus()
		edit.caret_column = edit.text.length()


## Deletes a saved group or an unsaved draft row.
func _delete_alias(index: int, is_draft: bool) -> void:
	if is_draft:
		if index >= 0 and index < _alias_drafts.size():
			_alias_drafts.remove_at(index)
			page.rebuild_keep_scroll()
		return
	var groups := BookTags.clean_aliases(Settings.get_value("tag_aliases"))
	if index < 0 or index >= groups.size():
		return
	groups.remove_at(index)
	Settings.set_value("tag_aliases", BookTags.clean_aliases(groups))


## True when cleaning dropped a main tag or alias the user typed, so the save
## should say so (a repeated main tag and an alias claimed by an earlier group go).
func _aliases_dropped(groups: Array, cleaned: Array) -> bool:
	var want_mains := {}
	var want_alias := {}
	for g in groups:
		var m := _norm_tag(str(g.get("tag", "")))
		if m != "":
			want_mains[m] = true
		var a: Variant = g.get("aliases", [])
		var list: Array = a if a is Array else str(a).split(",")
		for t in list:
			var n := _norm_tag(str(t))
			if n != "" and n != m:
				want_alias[n] = true
	var got_mains := {}
	var got_alias := {}
	for g in cleaned:
		got_mains[_norm_tag(str(g.get("tag", "")))] = true
		for t in g.get("aliases", []):
			got_alias[_norm_tag(str(t))] = true
	for m in want_mains:
		if not got_mains.has(m):
			return true
	for n in want_alias:
		if not got_alias.has(n):
			return true
	return false


## Library tags that are in no alias group yet, as main tag or alias.
func _ungrouped_tags() -> Array:
	var grouped := {}
	for g in BookTags.clean_aliases(Settings.get_value("tag_aliases")):
		grouped[_norm_tag(g.tag)] = true
		for t in g.aliases:
			grouped[_norm_tag(t)] = true
	var out := []
	for t in BookTags.book_tags():
		if not grouped.has(_norm_tag(str(t))):
			out.append(str(t))
	return out


## A tag for comparing: lowercase with extra spaces collapsed, as cleaning it does.
static func _norm_tag(t: String) -> String:
	return " ".join(t.strip_edges().split(" ", false)).to_lower()


## A saved group's aliases as comma-separated text for its row.
static func _aliases_text(aliases: Variant) -> String:
	return ", ".join(PackedStringArray(aliases)) if aliases is Array else str(aliases)


# --- site rules --------------------------------------------------------------
