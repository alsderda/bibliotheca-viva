class_name WebExtract
## JavaScript injected into pages shown in the Web tab. It reads the page the
## user has open, reports what it found through window.ipc.postMessage, and
## highlights the paragraph being read.
##
## The generic part finds the text on any page. Plugins add a recogniser for
## their sites (their "web" script), which finds the novel's details, chapter
## list, chapter text and next/previous links. The user's site rules
## (SiteRules) come last and win over both. Nothing is crawled.


## The page script with every loaded plugin's recogniser and the user's site rules.
static func script() -> String:
	var parts := PackedStringArray()
	for p in Plugins.plugins:
		var js := p.web_script()
		if js.strip_edges() != "":
			parts.append("register(%s, function (h) { const { $, $$, textOf, abs, firstText } = h;\n%s\n});" % [JSON.stringify(p.id), js])
	return SCRIPT.replace("/*PLUGINS*/", "\n".join(parts)).replace("/*RULES*/[]", JSON.stringify(SiteRules.all()))


const SCRIPT := r"""
(function () {
  window.__srRules = /*RULES*/[];  // the user's site rules, fresh on every run
  if (window.__sr) { window.__sr.analyze(); return; }
  const post = (o) => window.ipc.postMessage(JSON.stringify(o));
  const style = document.createElement('style');
  style.textContent = `
    [data-sr-active] { background: rgba(90,169,255,.22) !important; border-radius: 6px;
      box-shadow: 0 0 0 6px rgba(90,169,255,.22); transition: background .2s, box-shadow .2s; }
    [data-sr-i] { cursor: auto; }
    [data-sr-new] { outline: 4px solid #5aa9ff !important; outline-offset: 3px; border-radius: 6px; }
    #sr-new-banner { box-sizing: border-box; margin: 12px 0; padding: 12px 16px; border-radius: 10px;
      background: #5aa9ff; color: #06121f; font: 600 16px/1.4 system-ui, sans-serif; display: flex; gap: 12px; align-items: center; }
    #sr-new-banner button:first-of-type { margin-left: auto; }
    #sr-new-banner button { border: 0; border-radius: 8px; padding: 6px 12px; cursor: pointer;
      background: rgba(6,18,31,.15); color: inherit; font: inherit; }
    #sr-new-banner.sr-floating { position: fixed; top: 12px; left: 50%; transform: translateX(-50%); z-index: 2147483647;
      max-width: calc(100% - 24px); box-shadow: 0 6px 24px rgba(0,0,0,.25); }`;
  document.documentElement.appendChild(style);

  const SELECTORS = ['article', 'main', '#content'];
  const BLOCKS = 'p,h1,h2,h3,h4,h5,h6,li,blockquote,pre';
  // site chrome inside chapter text; plugins add their own selectors
  let SKIP = '[data-sr-skip]';
  let blocks = [];
  let listing = { els: {}, anchor: null };  // the works on a list page, by link, to highlight new ones

  function visible(el) {
    const s = getComputedStyle(el);
    return s.display !== 'none' && s.visibility !== 'hidden' && s.speak !== 'never' && el.getClientRects().length > 0;
  }
  function textOf(el) { return (el.innerText || '').replace(/\s+/g, ' ').trim(); }

  function contentRoot() {
    for (const sel of SELECTORS) {
      const el = document.querySelector(sel);
      if (el && textOf(el).length > 400) return el;
    }
    let best = null, score = 0;
    document.querySelectorAll('div, section, article, main').forEach((el) => {
      let t = 0;
      for (const c of el.children) if (c.tagName === 'P') t += (c.innerText || '').length;
      if (t > score) { score = t; best = el; }
    });
    return score > 400 ? best : null;
  }

  function collect(root, skip) {
    const all = [...root.querySelectorAll(BLOCKS)];
    // keep the innermost blocks only (a <p> inside a <blockquote> wins)
    return all.filter((el) => !el.querySelector(BLOCKS) && visible(el) && textOf(el) !== '' && !el.closest(skip));
  }

  // a user's selector may be mistyped: treat it as matching nothing
  function find(sel) {
    if (!sel) return null;
    try { return document.querySelector(sel); } catch (e) { return null; }
  }
  function validSelector(sel) {
    try { document.querySelector(sel); return true; } catch (e) { return false; }
  }
  function linkAt(sel) {
    const el = find(sel);
    const a = el && (el.closest('a[href]') || el.querySelector('a[href]'));
    return a && !a.href.startsWith('javascript') ? a.href : '';
  }

  // The user's rule for this site (see SiteRules): the longest matching host wins.
  function userRule() {
    const host = location.hostname.toLowerCase().replace(/^www\./, '');
    let best = {};
    for (const r of window.__srRules || []) {
      if (r.host && (host === r.host || host.endsWith('.' + r.host)) && !(best.host && best.host.length >= r.host.length)) best = r;
    }
    return best;
  }

  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => [...(root || document).querySelectorAll(sel)];
  const abs = (href) => new URL(href, location.href).href;
  const firstText = (...sels) => { for (const s of sels) { const el = $(s); if (el && textOf(el)) return textOf(el); } return ''; };

  // Site recognisers come from plugins (see PLUGINS.md): {hosts: RegExp, skip?: selector, info: async () => info | null}
  const SITES = [];
  const helpers = { $, $$, textOf, abs, firstText };
  function register(id, make) {
    try { const r = make(helpers); if (r && r.hosts && r.info) { r.id = id; SITES.push(r); if (r.skip) SKIP += ', ' + r.skip; } } catch (e) {}
  }
  /*PLUGINS*/

  async function siteInfo() {
    for (const r of SITES) {
      if (!r.hosts.test(location.hostname)) continue;
      try {
        const info = await r.info();
        if (info) { info.site = r.id; return info; }
      } catch (e) {}
      return null;
    }
    return null;
  }

  function linkMatching(re) {
    const rel = document.querySelector('link[rel=next], a[rel=next]');
    if (re.source.startsWith('^\\s*next') && rel && rel.href) return rel.href;
    const a = [...document.querySelectorAll('a[href]')].find((a) => re.test(textOf(a)) && !a.href.startsWith('javascript'));
    return a ? a.href : '';
  }

  async function analyze() {
    const challenge = !!document.querySelector('#anubis_challenge, #challenge-form, #cf-challenge-running') ||
      /Just a moment|not a bot|Attention Required/i.test(document.title);
    blocks.forEach((el) => { el.removeAttribute('data-sr-i'); el.removeAttribute('data-sr-active'); });
    const site = (challenge ? null : await siteInfo()) || { site: location.hostname.replace(/^www\./, '') };
    const user = challenge ? {} : userRule();
    const mine = find(user.content);
    let root = null;
    if (mine && textOf(mine)) root = mine;
    else if (!challenge) root = site.content && textOf(site.content) ? site.content : contentRoot();
    delete site.content;
    if (site.listing && Array.isArray(site.listing.items)) {
      // works on a search or list page: keep their elements here, send only the links
      listing = { els: {}, anchor: site.listing.anchor || null };
      site.listing.works = site.listing.items.filter((it) => it && it.url).map((it) => { listing.els[it.url] = it.el; return it.url; });
      delete site.listing.items;
      delete site.listing.anchor;
    }
    const skip = user.skip && validSelector(user.skip) ? SKIP + ', ' + user.skip : SKIP;
    blocks = root ? collect(root, skip) : [];
    if (!site.fictionUrl) {
      const h = root && root.parentElement ? root.parentElement.querySelector('h1, h2, h3') : document.querySelector('h1');
      site.chapterTitle = h ? textOf(h) : document.title;
      site.fictionTitle = document.title.split(/ [-|–] /).pop().trim();
      site.isChapter = blocks.length > 3 || (root === mine && blocks.length > 0);
    }
    const title = find(user.title);
    if (title && textOf(title)) site.chapterTitle = textOf(title);
    let firstVisible = 0;
    const paragraphs = blocks.map((el, i) => {
      el.setAttribute('data-sr-i', i);
      if (!firstVisible && el.getBoundingClientRect().bottom > 0) firstVisible = i;
      return { t: el.innerText.replace(/[ \t]+/g, ' ').trim(), k: /^H[1-6]$/.test(el.tagName) ? 'h' : 'p', h: el.outerHTML.slice(0, 20000) };
    });
    const page = Object.assign({ type: 'page', url: location.href, title: document.title, challenge, firstVisible, paragraphs,
      next: linkMatching(/^\s*next(\s*chapter)?\s*[»>→]?\s*$/i), prev: linkMatching(/^\s*[«<←]?\s*prev(ious)?(\s*chapter)?\s*$/i) }, site);
    page.next = linkAt(user.next) || page.next;
    page.prev = linkAt(user.prev) || page.prev;
    page.siteRule = user.host || '';
    post(page);
  }

  document.addEventListener('dblclick', (e) => {
    const el = e.target.closest && e.target.closest('[data-sr-i]');
    if (el) post({ type: 'jump', i: Number(el.getAttribute('data-sr-i')) });
  });

  window.__sr = {
    analyze,
    highlight(i, follow) {
      blocks.forEach((el) => el.removeAttribute('data-sr-active'));
      const el = blocks[i];
      if (!el) return;
      el.setAttribute('data-sr-active', '');
      if (follow) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
    },
    clear() { blocks.forEach((el) => el.removeAttribute('data-sr-active')); },
    go(url) { location.href = url; },
    // highlight works that are new on a saved search, with a note above the list
    markNew(urls, text) {
      document.querySelectorAll('[data-sr-new]').forEach((el) => el.removeAttribute('data-sr-new'));
      const old = document.getElementById('sr-new-banner');
      if (old) old.remove();
      const els = urls.map((u) => listing.els[u]).filter(Boolean);
      if (!els.length) return;
      els.forEach((el) => el.setAttribute('data-sr-new', ''));
      const banner = document.createElement('div');
      banner.id = 'sr-new-banner';
      banner.textContent = text;
      const show = document.createElement('button');
      show.textContent = 'Show first';
      show.onclick = () => els[0].scrollIntoView({ block: 'center', behavior: 'smooth' });
      const close = document.createElement('button');
      close.textContent = '✕';
      close.title = 'Close';
      close.onclick = () => banner.remove();
      banner.append(show, close);
      const anchor = listing.anchor && listing.anchor.parentNode ? listing.anchor : null;
      if (anchor) anchor.parentNode.insertBefore(banner, anchor);
      else { banner.classList.add('sr-floating'); document.body.appendChild(banner); }
    },
  };
  analyze();
})();
"""
