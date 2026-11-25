class_name ChapterMoves
## Which chapter files of a book move or get deleted when its chapter list changes.
## Matched by chapter link, so a chapter keeps its file (and its word count) when
## its place in the list moves. Library runs these in replace_chapters and _recover_replace.


## Which old chapter indexes carry over to which new ones, matched by chapter
## link; each kept chapter's word count moves onto its new entry. Moves that
## overlap (old 2 -> new 3 while old 3 -> new 2) are safe: nothing is renamed
## onto a file that still has to move.
static func chapter_moves(old_chapters: Array, new_chapters: Array) -> Array:
	var moves := []
	for old_i in old_chapters.size():
		var key := Library.chapter_key(str(old_chapters[old_i].get("url", "")))
		for new_i in new_chapters.size():
			if Library.chapter_key(str(new_chapters[new_i].get("url", ""))) == key:
				moves.append([old_i, new_i])
				if (old_chapters[old_i] as Dictionary).has("words"):
					new_chapters[new_i].words = old_chapters[old_i].words
				break
	return moves


## The book folder's chapter file indexes: every <int>.json in it, nothing else.
static func chapter_files(dir: String) -> Array:
	var out := []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".json") and f.get_basename().is_valid_int():
			out.append(f.get_basename().to_int())
	return out


## Deletes the book folder's chapter files no move targets: chapters that are
## really gone (and stale files past the list). Only <int>.json files.
static func drop_unkept_chapters(dir: String, moves: Array) -> void:
	var keep := {}
	for mv in moves:
		keep[int(mv[1])] = true
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".json") and f.get_basename().is_valid_int() and not keep.has(f.get_basename().to_int()):
			d.remove(f)
