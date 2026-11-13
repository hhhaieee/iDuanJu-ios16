// 18comic（禁漫天堂）· i短剧 idj1 漫画插件
// - 镜像：设置里可选；「自动」时依次尝试上次可用的镜像 → 内置镜像 → 发布页（jmcomicgo.org）上列出的、且已在白名单内的域名。
// - Cloudflare：插件声明了 cloudflare 权限，宿主在本插件独立的隐藏 WebView 里过验证，cookie 只进本插件。
// - 图片分段打乱：按公开的 JM 算法算出分段数，交给宿主原生还原（transform: stripes）。
const MIRRORS = ['18comic.ink', '18comic.vip', 'jmcomic-zzz.one', 'jmcomic-zzz.org', 'comic18j-nini.com', 'comic18j-nico.site', 'comic18j-ada.work'];
const PUBLISH = 'https://jmcomicgo.org/';
const SCRAMBLE_DEFAULT = 220980;

function setting() { const m = (host.settings.mirror || '').trim(); return m && m !== '自动' ? m : ''; }
function candidates() {
  const fixed = setting();
  if (fixed) return [fixed];
  const last = host.storage.get('mirror');
  const list = (host.storage.get('discovered') || []).concat(MIRRORS);
  return (last ? [last] : []).concat(list.filter(d => d !== last)).filter((d, i, a) => a.indexOf(d) === i);
}
function looksOK(res) {
  return res.status >= 200 && res.status < 300 && isSite(res.body) && !/<title>\s*Just a moment|_cf_chl_opt/.test(res.body);
}
function isSite(body) { return /禁漫|18comic|jmcomic/i.test(String(body || '')); 
}

async function discover() {
  try {
    const res = await host.http.request({ url: PUBLISH, timeout: 10000, cloudflare: 'off' });
    const found = [];
    for (const m of String(res.body).matchAll(/\b((?:[a-z0-9-]+\.)+[a-z]{2,})\b/gi)) {
      const d = m[1].toLowerCase();
      if (/googletagmanager|gmail|discord|t\.me|jm-uu|jm365|jmcomicgo|jmcomictt/.test(d) || found.includes(d)) continue;
      if (host.http.allowed('https://' + d + '/')) found.push(d);
      else host.log('发布页上的新域名不在白名单，需要在插件详情里手动添加：' + d);
    }
    if (found.length) host.storage.set('discovered', found);
    return found;
  } catch (e) { host.log('发布页读取失败', e.message); return []; }
}

/** GET path on a working mirror; returns { res, base }. */
async function fetchPage(path) {
  let lastErr = null;
  const tried = {};
  const attempt = async (list) => {
    for (const d of list) {
      if (tried[d]) continue;
      tried[d] = 1;
      const base = 'https://' + d;
      try {
        const res = await host.http.request({ url: base + path, headers: { Referer: base + '/' }, timeout: 15000 });
        if (res.status === 404 && isSite(res.body)) throw host.error('E_NOT_FOUND', '页面不存在：' + path);
        if (looksOK(res)) { if (!setting()) host.storage.set('mirror', d); return { res, base }; }
        lastErr = host.error('E_HTTP', d + ' 返回 HTTP ' + res.status);
      } catch (e) {
        if (e.code === 'E_NOT_FOUND') throw e;
        lastErr = e;
        host.log(d + ' 不可用：' + (e.code || '') + ' ' + e.message);
      }
    }
    return null;
  };
  const r = (await attempt(candidates())) || (setting() ? null : await attempt(await discover()));
  if (r) return r;
  throw lastErr || host.error('E_HTTP', '所有镜像都不可用');
}
async function getDoc(path) { const { res, base } = await fetchPage(path); return { doc: host.html.parse(res.body, res.url), body: res.body, base }; }

function abs(base, u) {
  if (!u) return '';
  u = String(u).trim();
  if (u.startsWith('//')) return 'https:' + u;
  if (u.startsWith('/')) return base + u;
  return u.replace(/^http:\/\//, 'https://');
}
function clean(t) { return String(t || '').replace(/\s+/g, ' ').trim(); }

function parseCards(doc, base) {
  const items = [], seen = {};
  for (const col of doc.select('div.list-col')) {
    const a = col.selectFirst('a[href^="/album/"]');
    if (!a) continue;
    const m = a.attr('href').match(/^\/album\/(\d+)/);
    if (!m || seen[m[1]]) continue;
    seen[m[1]] = 1;
    const img = a.selectFirst('img');
    const titleEl = col.selectFirst('.video-title');
    const cat = col.selectFirst('.label-category');
    items.push({
      id: m[1],
      title: clean((img && (img.attr('title') || img.attr('alt'))) || (titleEl ? titleEl.text() : '')),
      cover: img ? abs(base, img.attr('data-original') || img.attr('src')) : '',
      remarks: cat ? clean(cat.text()) : '',
      tags: col.select('.tags a.tag, a.tag').map(t => clean(t.text())).filter(Boolean).slice(0, 20)
    });
  }
  return items.filter(i => i.title);
}
function hasNext(doc, page) {
  return doc.select('a.prevnext').some(a => a.attr('href').includes('page=' + (page + 1)));
}

const CATEGORIES = [
  ['mr', '最新'], ['mv', '最多观看'], ['tf', '最多爱心'],
  ['c:doujin', '同人'], ['c:single', '单本'], ['c:short', '短篇'], ['c:hanman', '韩漫'], ['c:meiman', '美漫'], ['c:another', '其他']
].map(([id, name]) => ({ id, name, isRank: id === 'mv' || id === 'tf' }));

/** 公开 JM 算法（JMComic-Crawler-Python, MIT）：分段数 */
function segments(scrambleId, aid, filename) {
  if (aid < scrambleId) return 0;
  if (aid < 268850) return 10;
  const x = aid < 421926 ? 10 : 8;
  const h = host.crypto.md5(String(aid) + filename, { out: 'hex' });
  return (h.charCodeAt(h.length - 1) % x) * 2 + 2;
}

export default {
  async home() {
    const { doc, base } = await getDoc('/albums?o=mr&page=1');
    return { categories: CATEGORIES, items: parseCards(doc, base), hasMore: hasNext(doc, 1) };
  },

  async category({ id, page = 1 }) {
    const path = id.startsWith('c:') ? '/albums/' + id.slice(2) + '?o=mr&page=' + page : '/albums?o=' + encodeURIComponent(id) + '&page=' + page;
    const { doc, base } = await getDoc(path);
    const items = parseCards(doc, base);
    return { items, hasMore: items.length > 0 && hasNext(doc, page) };
  },

  async search({ keyword, page = 1 }) {
    const { doc, base } = await getDoc('/search/photos?search_query=' + encodeURIComponent(keyword) + '&page=' + page);
    const items = parseCards(doc, base);
    return { items, hasMore: items.length > 0 && hasNext(doc, page) };
  },

  async detail({ id }) {
    if (!/^\d+$/.test(String(id))) throw host.error('E_NOT_FOUND', '无效的本子 id');
    const { doc, base } = await getDoc('/album/' + id + '/');
    const h1 = doc.selectFirst('h1#book-name') || doc.selectFirst('h1');
    const img = doc.selectFirst('#album_photo_cover img');
    let desc = '';
    for (const h of doc.select('h2.p-t-5')) { const t = clean(h.text()); if (t.startsWith('敘述') || t.startsWith('叙述')) { desc = t.replace(/^敘述：|^叙述：/, ''); break; } }
    const chapters = [], seen = {};
    for (const a of doc.select('.episode a[data-album]')) {
      const pid = a.attr('data-album');
      if (!/^\d+$/.test(pid) || seen[pid]) continue;
      seen[pid] = 1;
      const h3 = a.selectFirst('h3');
      chapters.push({ id: pid, name: clean(h3 ? h3.text() : a.text()).replace(/\s.*$/, '') || ('第' + (chapters.length + 1) + '話'), idx: Number(a.attr('data-index') || chapters.length) });
    }
    chapters.sort((x, y) => x.idx - y.idx);
    const tags = [...new Set(doc.select('span[data-type="tags"] a').map(a => clean(a.text())).filter(Boolean))];
    const authors = [...new Set(doc.select('span[data-type="author"] a').map(a => clean(a.text())).filter(Boolean))];
    return {
      title: h1 ? clean(h1.text()) : id,
      cover: img ? abs(base, img.attr('data-original') || img.attr('src')) : '',
      desc,
      author: authors.join(' / '),
      tags,
      status: '',
      chapters: chapters.length ? chapters.map(c => ({ id: c.id, name: c.name })) : [{ id: String(id), name: '第1話' }]
    };
  },

  async pages({ chapterId }) {
    if (!/^\d+$/.test(String(chapterId))) throw host.error('E_NOT_FOUND', '无效的章节 id');
    const { doc, body, base } = await getDoc('/photo/' + chapterId + '/');
    const sm = body.match(/var\s+scramble_id\s*=\s*(\d+)/);
    const am = body.match(/var\s+aid\s*=\s*(\d+)/);
    const scrambleId = sm ? Number(sm[1]) : SCRAMBLE_DEFAULT;
    const aid = am ? Number(am[1]) : Number(chapterId);
    const seen = {};
    const urls = doc.select('img[data-original*="/media/photos/"]').map(i => abs(base, i.attr('data-original')))
      .filter(u => /^https:\/\//.test(u) && !seen[u] && (seen[u] = 1));
    if (!urls.length) throw host.error('E_PARSE', '章节里没有找到图片（可能需要登录或镜像异常）');
    return {
      headers: { Referer: base + '/' },
      images: urls.map(url => {
        const file = (url.split('?')[0].split('/').pop() || '');
        const name = file.replace(/\.[^.]+$/, '');
        if (/\.gif$/i.test(file)) return { url };
        const n = segments(scrambleId, aid, name);
        return n > 1 ? { url, transform: { type: 'stripes', segments: n } } : { url };
      })
    };
  }
};
