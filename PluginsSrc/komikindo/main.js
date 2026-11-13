// Komikindo（komikindo.click，MangaThemesia 主题）· i短剧 idj1 漫画插件
const SITE = 'https://komikindo.click';
const REF = { Referer: SITE + '/' };

function abs(u) {
  if (!u) return '';
  u = String(u).trim();
  if (u.startsWith('//')) return 'https:' + u;
  if (u.startsWith('/')) return SITE + u;
  return u.replace(/^http:\/\//, 'https://'); // 图床同时支持 https；App 只允许 https
}
function slugOf(href) { const m = String(href || '').match(/\/manga\/([^/?#]+)/); return m ? m[1] : ''; }

async function getText(path) {
  const res = await host.http.request({ url: abs(path), headers: REF, timeout: 15000 });
  if (res.status === 404) throw host.error('E_NOT_FOUND', '页面不存在：' + path);
  if (res.status < 200 || res.status >= 300) throw host.error('E_HTTP', 'HTTP ' + res.status + '：' + path);
  return res;
}
async function getDoc(path) { const r = await getText(path); return host.html.parse(r.body, r.url); }

function parseCards(doc) {
  const items = [], seen = {};
  for (const a of doc.select('.bsx a[href*="/manga/"]')) {
    const id = slugOf(a.attr('href'));
    if (!id || seen[id]) continue;
    seen[id] = 1;
    const img = a.selectFirst('img');
    const tt = a.selectFirst('.tt');
    const ep = a.selectFirst('.epxs');
    const type = a.selectFirst('.typename');
    items.push({
      id,
      title: (a.attr('title') || (tt ? tt.text() : '')).trim(),
      cover: img ? abs(img.attr('src') || img.attr('data-src')) : '',
      remarks: ep ? ep.text().trim() : '',
      tags: type ? [type.text().trim()] : []
    });
  }
  return items;
}
function hasNext(doc, page) {
  if (doc.selectFirst('.hpage a.r, a.next.page-numbers')) return true;
  const n = page + 1;
  return doc.select('a.page-numbers').some(a => { const h = a.attr('href'); return h.includes('page/' + n + '/') || h.includes('page=' + n); });
}

const CATEGORIES = [
  ['update', '最近更新'], ['popular', '热门'], ['latest', '最新上架'],
  ['g:manhwa', 'Manhwa'], ['g:manga', 'Manga'], ['g:full-color', 'Full Color'], ['g:romance', 'Romance'], ['g:drama', 'Drama'],
  ['g:comedy', 'Comedy'], ['g:harem', 'Harem'], ['g:fantasy', 'Fantasy'], ['g:mature', 'Mature'], ['g:milf', 'MILF'], ['g:webtoon', 'Webtoon']
].map(([id, name]) => ({ id, name }));

export default {
  async home() {
    const doc = await getDoc('/manga/?page=1&order=update');
    return { categories: CATEGORIES, items: parseCards(doc), hasMore: hasNext(doc, 1) };
  },

  async category({ id, page = 1 }) {
    const path = id.startsWith('g:')
      ? '/genres/' + id.slice(2) + '/' + (page > 1 ? 'page/' + page + '/' : '')
      : '/manga/?page=' + page + '&order=' + encodeURIComponent(id);
    const doc = await getDoc(path);
    const items = parseCards(doc);
    return { items, hasMore: items.length > 0 && hasNext(doc, page) };
  },

  async search({ keyword, page = 1 }) {
    const doc = await getDoc((page > 1 ? '/page/' + page + '/' : '/') + '?s=' + encodeURIComponent(keyword));
    const items = parseCards(doc);
    return { items, hasMore: items.length > 0 && hasNext(doc, page) };
  },

  async detail({ id }) {
    const doc = await getDoc('/manga/' + id + '/');
    const h1 = doc.selectFirst('h1.entry-title');
    const img = doc.selectFirst('.thumb img');
    const desc = doc.selectFirst('.entry-content-single');
    let status = '', author = '';
    for (const tr of doc.select('.infotable tr')) {
      const tds = tr.select('td');
      if (tds.length < 2) continue;
      const k = tds[0].text().trim().toLowerCase(), v = tds[1].text().trim();
      if (k === 'status') status = /complete|tamat/i.test(v) ? 'completed' : 'ongoing';
      if (k === 'author') author = v;
    }
    const chapters = [], seen = {};
    for (const a of doc.select('#chapterlist li a')) {
      const href = a.attr('href');
      const m = href.match(/^https:\/\/komikindo\.click\/([^/?#]+)\/?$/);
      if (!m || seen[m[1]] || !/chapter/i.test(m[1])) continue;
      seen[m[1]] = 1;
      const num = a.selectFirst('.chapternum');
      chapters.push({ id: m[1], name: (num ? num.text() : a.text()).trim() });
    }
    chapters.reverse(); // 新→旧 改为 旧→新
    return {
      title: h1 ? h1.text().trim() : id,
      cover: img ? abs(img.attr('src') || img.attr('data-src')) : '',
      desc: desc ? desc.text().trim() : '',
      author: author === 'N/A' ? '' : author,
      tags: doc.select('.seriestugenre a, .mgen a').map(a => a.text().trim()).filter(Boolean),
      status,
      chapters
    };
  },

  async pages({ chapterId }) {
    const r = await getText('/' + chapterId + '/');
    const m = r.body.match(/ts_reader\.run\((\{[\s\S]*?\})\);/);
    let urls = [];
    if (m) {
      try {
        const o = JSON.parse(m[1]);
        const src = (o.sources || []).find(s => (s.images || []).length) || {};
        urls = (src.images || []).map(abs);
      } catch (e) { host.log('ts_reader JSON 解析失败', String(e)); }
    }
    if (!urls.length) urls = host.html.parse(r.body, r.url).select('#readerarea img').map(i => abs(i.attr('src') || i.attr('data-src')));
    urls = urls.filter(u => /^https:\/\//.test(u));
    if (!urls.length) throw host.error('E_PARSE', '章节里没有找到图片：' + chapterId);
    return { images: urls.map(url => ({ url })), headers: REF };
  }
};
