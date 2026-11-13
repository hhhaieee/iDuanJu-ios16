// Manga18fx · i短剧 idj1 漫画插件（单文件，只用 host.* 能力）
const SITE = 'https://manga18fx.com';

function abs(u) {
  if (!u) return '';
  u = String(u).trim();
  if (u.startsWith('//')) return 'https:' + u;
  if (u.startsWith('/')) return SITE + u;
  return u.replace(/^http:\/\//, 'https://');
}
function slugOf(href) { const m = String(href || '').match(/\/manga\/([^/?#]+)/); return m ? m[1] : ''; }

async function getDoc(path) {
  const res = await host.http.request({ url: abs(path), headers: { Referer: SITE + '/' }, timeout: 15000 });
  if (res.status === 404) throw host.error('E_NOT_FOUND', '页面不存在：' + path);
  if (res.status < 200 || res.status >= 300) throw host.error('E_HTTP', 'HTTP ' + res.status + '：' + path);
  return host.html.parse(res.body, res.url);
}

function parseCards(doc) {
  const items = [], seen = {};
  for (const card of doc.select('.bsx-item')) {
    const a = card.selectFirst('.bigor-manga h3 a') || card.selectFirst('a[href*="/manga/"]');
    const id = a ? slugOf(a.attr('href')) : '';
    if (!id || seen[id]) continue;
    seen[id] = 1;
    const img = card.selectFirst('img');
    const latest = card.selectFirst('.list-chapter a, .chapter-item a, .chapter a');
    items.push({
      id,
      title: (a.attr('title') || a.text()).trim(),
      cover: img ? abs(img.attr('data-src') || img.attr('src')) : '',
      remarks: latest ? latest.text().trim() : ''
    });
  }
  return items;
}
function hasNext(doc, page) { return doc.select('a[href$="/' + (page + 1) + '"]').length > 0; }

const CATEGORIES = [
  ['latest', '最新更新'], ['manhwa', 'Manhwa'], ['uncensored-manhwa', 'Uncensored'], ['romance', 'Romance'], ['drama', 'Drama'],
  ['comedy', 'Comedy'], ['harem', 'Harem'], ['fantasy', 'Fantasy'], ['isekai', 'Isekai'], ['mature', 'Mature'], ['seinen', 'Seinen'],
  ['action', 'Action'], ['mystery', 'Mystery'], ['psychological', 'Psychological'], ['supernatural', 'Supernatural'], ['manhua', 'Manhua']
].map(([id, name]) => ({ id, name }));

export default {
  async home() {
    const doc = await getDoc('/');
    return { categories: CATEGORIES, items: parseCards(doc), hasMore: true };
  },

  async category({ id, page = 1 }) {
    const path = id === 'latest' ? (page > 1 ? '/page/' + page : '/') : '/manga-genre/' + id + (page > 1 ? '/' + page : '');
    const doc = await getDoc(path);
    const items = parseCards(doc);
    return { items, hasMore: items.length > 0 && hasNext(doc, page) };
  },

  async search({ keyword, page = 1 }) {
    if (page > 1) return { items: [], hasMore: false };
    const doc = await getDoc('/search?q=' + encodeURIComponent(keyword));
    return { items: parseCards(doc), hasMore: false };
  },

  async detail({ id }) {
    const doc = await getDoc('/manga/' + id);
    const h1 = doc.selectFirst('.post-title h1') || doc.selectFirst('h1');
    const img = doc.selectFirst('.summary_image img');
    const desc = doc.selectFirst('.dsct');
    const chapters = [], seen = {};
    for (const a of doc.select('ul.row-content-chapter li a.chapter-name')) {
      const m = a.attr('href').match(/\/manga\/[^/]+\/([^/?#]+)/);
      if (m && !seen[m[1]]) { seen[m[1]] = 1; chapters.push({ id: id + '/' + m[1], name: a.text().trim() }); }
    }
    chapters.reverse(); // 站点新→旧，统一成旧→新
    let status = '';
    for (const it of doc.select('.post-status .summary-content, .post-content_item')) {
      const t = it.text().toLowerCase();
      if (t.includes('completed')) status = 'completed'; else if (t.includes('ongoing')) status = 'ongoing';
    }
    const author = doc.selectFirst('.author-content a');
    return {
      title: h1 ? h1.text().trim() : id,
      cover: img ? abs(img.attr('data-src') || img.attr('src')) : '',
      desc: desc ? desc.text().trim() : '',
      author: author ? author.text().trim() : '',
      tags: doc.select('.genres-content a').map(a => a.text().trim()).filter(Boolean),
      status,
      chapters
    };
  },

  async pages({ chapterId }) {
    const doc = await getDoc('/manga/' + chapterId);
    const urls = doc.select('.read-content img')
      .map(img => abs(img.attr('data-src') || img.attr('src')))
      .filter(u => /^https:\/\/img\d*\.manga18fx\.com\//.test(u));
    if (!urls.length) throw host.error('E_PARSE', '章节里没有找到图片：' + chapterId);
    return { images: urls.map(url => ({ url })), headers: { Referer: SITE + '/' } };
  }
};
