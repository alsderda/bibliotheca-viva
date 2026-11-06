# Writing a plugin

Every site Bibliothéca-viva can search, add books from and download chapters from is a plugin. A plugin is a folder:

```
my-site/
  plugin.json   what the plugin is
  source.gd     the code: a class that extends SourcePlugin
  web.js        optional: recognises the site's pages in the Web tab
```

The app loads plugins at runtime, so they can be installed into a finished app: from a link, from a plugin repository, from a folder (desktop), or by Sync from another device. While you work on a plugin, put its folder (or a clone of its repository) in the project's `plugins/` folder, which git ignores. The app loads it from there each time it starts.

## plugin.json

```json
{
	"id": "mysite",
	"name": "My Site",
	"version": "1.0.0",
	"api": 1,
	"description": "One or two sentences shown in Browse and Settings: what works, and what needs the Web tab.",
	"author": "you",
	"license": "GPL-3.0",
	"home": "https://www.mysite.example/",
	"domains": ["mysite.example"],
	"needs": ["http"],
	"main": "source.gd",
	"web": "web.js",
	"files": ["source.gd", "web.js"]
}
```

| Field | |
| --- | --- |
| `id` | Lowercase letters, digits, `-` and `_`. Books store it as their `source`, so don't change it later. |
| `version` | Dotted numbers. A higher version replaces a lower one on install and through Sync. |
| `api` | The plugin API version it was written for. This app has API 1 (`Plugins.API`). |
| `domains` | Links on these hosts (and their subdomains) belong to the plugin. |
| `home` | Start page offered in the Web tab's site menu. Optional. |
| `needs` | `http`: plain HTTP requests, works everywhere. `process`: runs a program, desktop only (hidden on phones). |
| `files` | Every file the plugin consists of, besides `plugin.json`. Installing from a link downloads exactly these. Subfolders are fine (`backend/server.py`). |
| `keep` | Files or folders the plugin creates for itself that survive updates (e.g. `"backend/.venv"`). Optional. |
| `search` | `false` if the plugin can't search. Optional. |
| `request_gap` | Seconds the app waits after each request to the plugin's domains before sending the next (default 1, up to 60). Optional. |

## source.gd

```gdscript
extends SourcePlugin

const BASE := "https://www.mysite.example"


func book_key(url: String) -> String:
	var m := re("mysite\\.example/story/(\\d+)").search(url)
	return "mysite:" + m.get_string(1) if m else ""


func search(query: String, _source_key := "") -> Dictionary:
	var r: Dictionary = await Net.get_text(BASE + "/search?q=" + query.uri_encode())
	if is_blocked(r):
		return {"results": [], "error": blocked_message(), "blocked": true}
	...
	return {"results": [{"title": "…", "url": "…", "cover_url": "", "info": "12 chapters"}], "error": ""}


func fetch_novel(url: String) -> Dictionary:
	...
	return {"novel": {"title": "…", "author": "…", "cover_url": "…", "synopsis": "…", "tags": [],
		"url": "…", "chapters": [{"title": "…", "url": "…", "date": 0}],
		"extra": {"status": "completed"},  # optional, kept on the book for library filters
		"words": 0}, "error": ""}  # optional: the book's word count as the site reports it


func fetch_chapter(_book: Dictionary, chapter: Dictionary, _index: int) -> Dictionary:
	var r: Dictionary = await Net.get_text(chapter.url)
	if is_blocked(r):
		return {"error": "blocked"}
	return {"title": "…", "paragraphs": HtmlText.to_paragraphs(element(r.text, "<div[^>]*id=\"text\"")), "error": ""}
```

Don't give the script a `class_name`: scripts loaded at runtime can't register one. Use the app's own classes and autoloads instead (`Net`, `HtmlText`, `Library`, `UI`, …).

Everything in `SourcePlugin` has a default, so override only what the site supports:

| Method | |
| --- | --- |
| `handles_url(url)` | Default: the `domains` from plugin.json. |
| `book_key(url)`, `chapter_key(url)` | The same book or chapter under different links (slugs, mobile hosts, queries) gets one key. `""` compares plain links. Keep keys stable: Sync uses them to match chapters across devices. |
| `search_sources()`, `search(query, key)` | The entries Browse lists for this plugin, and the search itself. |
| `search_url(query)` | The site's own search page, offered in the Web tab when the app is blocked. |
| `fetch_novel(url)`, `fetch_chapter(book, chapter, index)` | Add a book by link (also used to check for new chapters), and download one chapter. Return `"blocked": true` / `"error": "blocked"` for a bot check. Chapters may carry `excerpt_html` (e.g. from a feed): the app keeps it as a preview until the full text is downloaded. If the site shows the book's word count, return it as `words`: the book page shows it next to the count of the saved chapters (the app counts those itself). |
| `library_filters()`, `library_filter_matches(book, key, value)` | Extra filters on the Library page, shown once the plugin is picked as the source: `[{"key": "status", "label": "Status", "options": [{"key": "completed", "label": "Completed"}]}]`. The app adds "Any" to each. By default a book matches when the `extra` from `fetch_novel` has that value under `key` (or contains it, for a list); override `library_filter_matches` for anything else. No filters: none are shown. |
| `is_listing_url`, `listing_name`, `listing_tip` | Saved searches: a page that lists works can be saved. A saved search is a link: the app never fetches it. When you open it in the Web tab, the works on the page (see web.js) are compared with the ones seen last time, and new ones are highlighted. Where there's no Web tab (Android), it opens in the system browser. |
| `setup()`, `shutdown()` | Start and stop background work (e.g. a local server). |
| `status()`, `status_changed` | For plugins that run a helper: shown in the sidebar and in Browse → Sources. |
| `card_controls()`, `settings_rows()` | Extra controls in Browse → Sources and Settings → Plugins. |
| `get_setting(key, default)`, `set_setting(key, value)` | The plugin's own settings. They stay on the device. |
| `notify(text, kind)` | Show a short message. |
| `run_tests(check)` | Checks run by the self-test: `check.call(name, got, want)`. |

Helpers for reading HTML: `re(pattern)`, `text(html)`, `element(html, open_tag_re)`, `until_close(html, start)`, `absolute(url, base)`, `paragraphs(html, drop_re)`, `synopsis(html)`, `is_blocked(response)`, `blocked_message()`.

### Requests are paced for you

Every `Net` request waits its turn in a queue for its site, so the app never sends a site more than one request at a time. After each one it waits `request_gap` seconds (default 1) before sending the next. Images wait in their host's queue too, ahead of pages, so cover CDNs and other hosts also get one request at a time with a 1-second gap. If a site answers 429 or 503 with no bot check, its queue pauses for the site's full `Retry-After` (or a growing wait) and the request is tried once more. While more than a minute of that break is left, requests to the site fail at once instead of waiting. The break still holds after the app is restarted (Settings → Sites → Keep site waits after a restart, on by default). A site that isn't answering (timeouts, failed connections, 5xx errors other than 503) gets a break too: 1 minute at first, growing to an hour while it keeps failing, during which its requests fail at once. Pages that come with an `ETag` or `Last-Modified` are kept and asked for again with `If-None-Match` / `If-Modified-Since`; on a 304 the plugin gets the kept page as a normal 200, so it needs no changes (Settings → Sites can turn this off). When a site shows a bot check, Check for updates stops asking it for the rest of that run. The same GET asked for twice at once is downloaded only once. So a plugin doesn't need its own delays, and can fetch a paged table of contents in a plain loop. `pause(seconds)` is still there if a site needs more.

A `process` plugin's own program makes its own requests, outside these queues, so it has to pace them itself.

Don't work around bot checks. When a site shows the app one, return `blocked`: the app offers the Web tab, where the real browser passes it.

## web.js

Runs inside pages open in the Web tab. Its body gets the helpers `$`, `$$`, `textOf`, `abs` and `firstText`, and returns a recogniser:

```js
function recognise() {
  const m = location.pathname.match(/^\/story\/(\d+)/);
  if (!m) return null;
  return {
    fictionUrl: location.origin + '/story/' + m[1],
    fictionTitle: firstText('h1'),
    isChapter: /\/chapter\//.test(location.pathname),
    fiction: { title: firstText('h1'), author: '', cover_url: '', synopsis: '', tags: [], words: 0,
      chapters: $$('.toc a').map((a) => ({ title: textOf(a), url: a.href, date: 0 })) },
    content: $('#text'),   // the chapter text, on chapter pages
    next: '', prev: '',    // only if the page has no "Next" / "Previous" link
  };
}

return { hosts: /(^|\.)mysite\.example$/, skip: '.author-note', info: recognise };
```

`info` may be `async`. `skip` is a CSS selector for site chrome inside the chapter text that shouldn't be read aloud. A page that lists works can return `{ isChapter: false, listing: { name, count, items, anchor } }` to offer Save search. `items` is `[{ url, el }]`, each work's link and its element on the page, so the app can highlight the works that are new on a saved search. `anchor` is the list element; the note about new works goes above it. Leave out anything the page doesn't have; the app reads the text of any page by itself. Users can override the chapter text, skipped parts, next/previous links and chapter title with their own site rules (Settings → Sites); those win over what `web.js` returns.

## Plugin repositories

A repository is a folder on the web with an `index.json` that lists plugin folders:

```json
{
	"name": "My plugins",
	"plugins": [{"path": "mysite"}, {"path": "othersite"}]
}
```

The app reads each folder's `plugin.json` for its name, version and description, so the version lives in one place. A repository with a single plugin at its top uses `{"path": ""}`. For GitHub, paste the repository's page; the app reads its files from `raw.githubusercontent.com` (public repositories only).

## Sync

With Sync on, installing, updating or removing a plugin on one device does the same on the others. Each version's files go to `bibliotheca-viva/plugins/<id>/<version>/` on the server once, and each device lists what it has installed in its own state file. Plugins are brought up to date before books are merged, so every device identifies books and chapters the same way. A device reads each plugin's `plugin.json` first and skips plugins it can't run (a newer plugin API, or `process` on a phone) without downloading their files. If a plugin's files can't be downloaded, only that plugin is skipped; it's tried again on the next sync.

## Testing

```sh
godot --path . -- --profile=selftest --selftest                          # runs every loaded plugin's run_tests()
godot --path . -- --profile=plugintest --plugintest=<repository> --live  # install from a link, then try each site
```
