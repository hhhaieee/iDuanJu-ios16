// 爱看机器人（ikanbot）· 黑果夜剧 idj1 适配插件
// 主体逻辑来自 guoapp-modules/ikanbot v1.0.4（MIT），原样嵌入；
// 外层把 guoapp 的 host.* 能力映射到 idj1 沙箱，并把导出函数桥接到 idj1 视频协议。
// 注意：idj1 沙箱以 ES module 加载插件，要求顶层 export default 一个对象；
// 这里用 IIFE 隔离内部作用域（避免内部变量遮蔽宿主注入的全局 host），再把它接住导出。

var _plugin = (function () {
  'use strict';

  // ---- guoapp host 兼容层 ----
  // 注意：idj1 的 host.http.request 底层是同步的（C 桥接 semaphore），所以这里
  // 全部按同步语义实现，正好匹配 ikanbot 的 goja 同步调用风格。
  var IK_SOURCE = 'ikanbot';
  var compatHost = {
    source: IK_SOURCE,
    dramaId: function (id) { return IK_SOURCE + ':' + id; },
    chapterId: function (id, order) { return IK_SOURCE + ':' + id + ':' + order; },
    fetchText: function (o) {
      var headers = { 'User-Agent': o.userAgent || 'Mozilla/5.0', 'Referer': o.referer || '' };
      var headersIn = (o && o.headers) || {};
      for (var k in headersIn) headers[k] = headersIn[k];
      var res = host.http.requestSync({ url: o.url, headers: headers, timeout: o.timeout || 20000 });
      return { body: typeof res.body === 'string' ? res.body : JSON.stringify(res.body), url: res.url, status: res.status };
    },
    fetch: function (o) {
      var res = host.http.requestSync({ url: o.url, headers: o.headers || {}, timeout: 20000 });
      return { body: typeof res.body === 'string' ? res.body : JSON.stringify(res.body), url: res.url, status: res.status };
    },
    parseHtml: function (text) { return host.html.toTree(text); },
    parseUrl: function (value) {
      var s = String(value || '');
      var m = /^https?:\/\/([^\/?#]+)([^#]*)?/.exec(s);
      if (!m) return { href: s, hostname: '', host: '', pathname: '', path: '', search: '', protocol: '', username: '', password: '' };
      var authority = m[1];
      var at = authority.lastIndexOf('@');
      var userInfo = at >= 0 ? authority.slice(0, at) : '';
      var hostname = at >= 0 ? authority.slice(at + 1) : authority;
      var rest = m[2] || '';
      var q = rest.indexOf('?');
      var pathname = q >= 0 ? rest.slice(0, q) : rest;
      return { href: s, hostname: hostname, host: authority, pathname: pathname, path: pathname,
               search: q >= 0 ? rest.slice(q) : '', protocol: /^https:/.test(s) ? 'https:' : 'http:',
               userInfo: userInfo, username: userInfo.split(':')[0],
               password: userInfo.indexOf(':') >= 0 ? userInfo.slice(userInfo.indexOf(':') + 1) : '' };
    },
    preserveIntegers: function (s) {
      // idj1 的 JSON.parse 走 fragmentsAllowed，大数保持为 number；ikanbot 只在线路
      // resData 字符串里用 int id，这里透传即可（我们只取 flag/url 字段）。
      return String(s);
    },
    cacheGet: function (k) { try { return host.storage.get('ik:' + k) || null; } catch (e) { return null; } },
    cacheSet: function (k, v, ttl) { try { if (v == null) host.storage.remove('ik:' + k); else host.storage.set('ik:' + k, v); } catch (e) {} },
    log: function (msg) { host.log('[ikanbot] ' + msg); }
  };

  // ---- ikanbot 主体（原样，注入 compatHost 作为局部 host）----
  var IK = (function (host) {
// 爱看机器人（ikanbot）站源模块
// 从 guoappxp 的 ikanbot.go 移植：搜索式聚合站，线路接口需 current_id + e_token 签名。
// 运行环境是 goja：所有导出函数同步，访问网络只能走 host.*，域名需在 manifest.hosts。

const BASE = "https://www1.ikanbot.com";
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";
const PAGE_SIZE = 36;
const MAX_LINES = 40;
const LINE_TTL_MS = 10 * 60 * 1000;

const CATEGORIES = [
  { id: "movie-热门", name: "热门电影" },
  { id: "tv-热门", name: "热门剧集" },
  { id: "tv-国产剧", name: "国产剧" },
  { id: "tv-日剧", name: "日剧" },
  { id: "tv-韩剧", name: "韩剧" },
  { id: "tv-美剧", name: "美剧" },
  { id: "tv-英剧", name: "英剧" },
  { id: "tv-港剧", name: "港剧" },
  { id: "tv-日本动画", name: "日本动画" },
  { id: "tv-综艺", name: "综艺" },
  { id: "tv-纪录片", name: "纪录片" },
];

// ---------------- 通用工具 ----------------

function trim(value) {
  return String(value == null ? "" : value).replace(/\s+/g, " ").trim();
}

function nodeText(node) {
  if (!node) return "";
  var out = node.text || "";
  var children = node.children || [];
  for (var i = 0; i < children.length; i++) out += nodeText(children[i]);
  return out;
}

function attr(node, name) {
  if (!node || !node.attrs) return "";
  return node.attrs[name] || "";
}

function hasClass(node, name) {
  var value = attr(node, "class");
  if (!value) return false;
  var parts = value.split(/\s+/);
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === name) return true;
  }
  return false;
}

function findAll(root, test) {
  var found = [];
  if (!root) return found;
  var stack = [root];
  while (stack.length > 0) {
    var node = stack.pop();
    if (node.tag && test(node)) found.push(node);
    var children = node.children || [];
    for (var i = children.length - 1; i >= 0; i--) stack.push(children[i]);
  }
  return found;
}

function first(root, test) {
  var all = findAll(root, test);
  return all.length > 0 ? all[0] : null;
}

function byClass(node, name) {
  return first(node, function (item) { return hasClass(item, name); });
}

// 去标签、解实体、压缩空白（对应 ikanbotClean）
function clean(text) {
  var value = String(text == null ? "" : text).replace(/<[^>]+>/g, "");
  value = value.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, function (all, code) { return String.fromCharCode(Number(code) || 0); });
  return trim(value.replace(/\u3000/g, " "));
}

function fixUrl(raw) {
  var value = trim(raw);
  if (!value) return "";
  if (value.indexOf("//") === 0) value = "https:" + value;
  if (value.indexOf("http") !== 0) return "";
  return value.replace(/^(https?:\/\/)img9\.doubanio\.com\//i, "$1img3.doubanio.com/");
}

function numericId(value) {
  var text = trim(value);
  return /^\d{1,12}$/.test(text) && Number(text) > 0;
}

function categoryName(id) {
  for (var i = 0; i < CATEGORIES.length; i++) {
    if (CATEGORIES[i].id === id) return CATEGORIES[i].name;
  }
  return "";
}

function validCategory(category) {
  var value = category == null ? "" : String(category).trim();
  if (value === "") return true;
  if (value.length > 32 || /[|/\\\x00\r\n]/.test(value)) return false;
  return categoryName(value) !== "";
}

function kindOf(category) {
  return String(category || "").indexOf("movie-") === 0 ? "电影" : "剧集";
}

function getPage(url, referer) {
  var full = String(url).indexOf("http") === 0 ? url : BASE + url;
  var response = host.fetchText({
    url: full,
    referer: referer || BASE + "/",
    userAgent: UA,
  });
  return { body: response.body, url: response.url || full, root: host.parseHtml(response.body) };
}

// ---------------- 列表 / 搜索解析 ----------------

function parseCards(root, category) {
  var items = [];
  var seen = {};
  var cards = findAll(root, function (node) { return hasClass(node, "item"); });
  for (var i = 0; i < cards.length; i++) {
    var card = cards[i];
    var matched = /^\/play\/(\d+)/.exec(attr(card, "href"));
    if (!matched || !numericId(matched[1])) continue;
    var id = matched[1];
    if (seen[id]) continue;

    var image = first(card, function (node) { return node.tag === "img"; });
    var title = image ? clean(attr(image, "alt")) : "";
    if (!title) {
      var paragraph = first(card, function (node) { return node.tag === "p"; });
      title = paragraph ? clean(nodeText(paragraph)) : "";
    }
    if (!title) continue;
    seen[id] = true;
    items.push({
      id: host.dramaId(id),
      source: host.source,
      sourceId: id,
      title: title,
      name: title,
      cover: image ? fixUrl(attr(image, "data-src") || attr(image, "src")) : "",
      categoryName: kindOf(category),
      channelName: "爱看机器人",
    });
    if (items.length > 500) break;
  }
  return items;
}

function parseSearchCards(root) {
  var items = [];
  var seen = {};
  var blocks = findAll(root, function (node) { return hasClass(node, "media"); });
  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i];
    var link = first(block, function (node) {
      return node.tag === "a" && /^\/play\/(\d+)/.test(attr(node, "href")) &&
        hasClass(node, "title-text");
    });
    if (!link) continue;
    var matched = /^\/play\/(\d+)/.exec(attr(link, "href"));
    if (!matched || !numericId(matched[1])) continue;
    var id = matched[1];
    if (seen[id]) continue;
    var title = clean(nodeText(link));
    var image = first(block, function (node) { return node.tag === "img"; });
    if (!title && image) title = clean(attr(image, "alt"));
    if (!title) continue;
    seen[id] = true;
    var label = byClass(block, "label");
    var small = byClass(block, "small");
    items.push({
      id: host.dramaId(id),
      source: host.source,
      sourceId: id,
      title: title,
      name: title,
      cover: image ? fixUrl(attr(image, "data-src") || attr(image, "src")) : "",
      categoryName: "剧集",
      remark: label ? clean(nodeText(label)).slice(0, 64) : "",
      desc: small ? clean(nodeText(small)).slice(0, 512) : "",
      channelName: "爱看机器人",
    });
    if (items.length > 100) break;
  }
  return items;
}

function pageCount(body, page, count) {
  var maxPage = page;
  var pattern = /-p-(\d+)\.html/g;
  var matched;
  while ((matched = pattern.exec(body)) !== null) {
    var value = Number(matched[1]);
    if (value > maxPage && value < 100000) maxPage = value;
  }
  if (maxPage > page) return maxPage;
  return count >= PAGE_SIZE ? page + 1 : page;
}

// ---------------- 线路接口 ----------------

// 复刻页面 get_tks：取影片 ID 末 4 位，每位数字 n 得步长 n%3+1，
// 从令牌当前位置截 8 字符并推进 k+8 位。算错接口返回 -401。
function signToken(currentId, token) {
  var cid = String(currentId || "");
  var eToken = String(token || "");
  if (cid.length < 4 || eToken.length < 16) return "";
  var tail = cid.slice(cid.length - 4);
  var rest = eToken;
  var out = "";
  for (var i = 0; i < tail.length; i++) {
    var digit = Number(tail.charAt(i));
    if (!isFinite(digit)) return "";
    var start = digit % 3 + 1;
    if (start + 8 > rest.length) return "";
    out += rest.slice(start, start + 8);
    rest = rest.slice(start + 8);
  }
  return out;
}

function splitEpisodes(raw) {
  var pairs = [];
  var parts = String(raw || "").split("#");
  for (var i = 0; i < parts.length; i++) {
    var piece = trim(parts[i]);
    if (!piece) continue;
    var at = piece.indexOf("$");
    if (at < 0) continue;
    var name = trim(piece.slice(0, at));
    var address = trim(piece.slice(at + 1));
    // 少数线路在地址后再挂一个 "$线路名"，带着会 500
    var extra = address.indexOf("$");
    if (extra >= 0) address = trim(address.slice(0, extra));
    if (address) pairs.push({ name: name, url: address });
  }
  return pairs;
}

function fixMediaUrl(raw) {
  var value = trim(raw);
  if (!value) return "";
  if (value.indexOf("//") === 0) value = "https:" + value;
  if (!/^https?:\/\//i.test(value)) return "";
  var parsed = host.parseUrl(value);
  if (!parsed.hostname || parsed.userInfo) return "";
  if (!/\.(m3u8|mp4|ts)(\?|$|#)/i.test(value) && value.indexOf(".m3u8") < 0) return "";
  return value.replace(/\\\//g, "/");
}

function lineQuality(flag) {
  var matched = /(2160|1440|1080|720|480)/.exec(String(flag || "").toLowerCase());
  if (!matched) return 0;
  var value = Number(matched[1]);
  return value >= 480 && value <= 2160 ? value : 0;
}

// 从线路接口 JSON 整理出按分集数降序的线路列表
function parseLines(payload) {
  var lines = [];
  var seen = {};
  var list = payload && payload.data && payload.data.list ? payload.data.list : [];
  for (var i = 0; i < list.length; i++) {
    var entries;
    try {
      entries = JSON.parse(host.preserveIntegers(list[i].resData || "[]"));
    } catch (error) {
      continue;
    }
    if (!entries || !entries.length) continue;
    for (var j = 0; j < entries.length; j++) {
      var entry = entries[j];
      var episodes = [];
      var orders = {};
      var signature = "";
      var pairs = splitEpisodes(entry.url);
      for (var k = 0; k < pairs.length; k++) {
        var address = fixMediaUrl(pairs[k].url);
        if (!address) continue;
        var name = clean(pairs[k].name);
        var order = k + 1;
        var numbered = /(\d+)/.exec(name);
        if (numbered) {
          var parsed = Number(numbered[1]);
          if (parsed > 0 && parsed <= 100000) order = parsed;
        }
        if (orders[order]) continue;
        orders[order] = true;
        episodes.push({ name: name, url: address, order: order });
        signature += address + "\n";
      }
      if (episodes.length === 0 || seen[signature]) continue;
      seen[signature] = true;
      lines.push({ flag: trim(entry.flag), episodes: episodes });
    }
  }
  lines.sort(function (a, b) { return b.episodes.length - a.episodes.length; });
  if (lines.length > MAX_LINES) lines = lines.slice(0, MAX_LINES);
  return lines;
}

function fetchLines(sourceId, meta) {
  var currentId = meta && meta.currentId ? meta.currentId : sourceId;
  var token = meta && meta.token ? meta.token : "";
  var mType = meta && meta.mType ? meta.mType : "1";

  if (!token) {
    var page = getPage("/play/" + sourceId);
    var parsed = parsePlayPage(page.body, sourceId);
    currentId = parsed.currentId;
    token = parsed.token;
    mType = parsed.mType;
  }
  var signed = signToken(currentId, token);
  if (!signed) throw new Error("爱看机器人播放令牌无效，请刷新详情");
  if (!mType) mType = "1";

  var address = BASE + "/api/getResN?videoId=" + encodeURIComponent(currentId) +
    "&mtype=" + encodeURIComponent(mType) + "&token=" + encodeURIComponent(signed);
  var response = host.fetch({
    url: address,
    headers: {
      "User-Agent": UA,
      "Referer": BASE + "/play/" + sourceId,
      "Accept": "application/json, text/plain, */*",
    },
    limit: 4 << 20,
  });
  var payload;
  try {
    payload = JSON.parse(host.preserveIntegers(response.body));
  } catch (error) {
    throw new Error("爱看机器人线路返回无法解析");
  }
  if (payload.state !== 1) {
    throw new Error("爱看机器人线路获取失败：" + (trim(payload.message) || "unauthorized"));
  }
  var lines = parseLines(payload);
  if (lines.length === 0) throw new Error("爱看机器人暂无可播放线路");
  return lines;
}

// 带 10 分钟缓存的线路入口；实例间变量不共享，必须走 host.cacheSet
function cachedLines(sourceId, meta) {
  var key = "ikanbot-lines-" + sourceId;
  var cached = host.cacheGet(key);
  if (cached) {
    try {
      var lines = JSON.parse(cached);
      if (lines && lines.length) return lines;
    } catch (error) {
      host.cacheSet(key, null, 0);
    }
  }
  var fresh = fetchLines(sourceId, meta);
  host.cacheSet(key, JSON.stringify(fresh), LINE_TTL_MS);
  return fresh;
}

function lineEpisode(line, order) {
  for (var i = 0; i < line.episodes.length; i++) {
    if (line.episodes[i].order === order) return line.episodes[i];
  }
  if (line.episodes.length === 1 && order === 1) return line.episodes[0];
  return null;
}

// ---------------- 详情 / 必需导出 ----------------

function parsePlayPage(body, sourceId) {
  var root = host.parseHtml(body);
  var titleNode = first(root, function (node) { return node.tag === "h1" && attr(node, "id") === "video_title"; });
  var title = titleNode ? clean(nodeText(titleNode)) : "";
  if (!title) throw new Error("爱看机器人详情缺少视频名称");

  var cover = "";
  var coverNode = first(root, function (node) {
    return node.tag === "img" && hasClass(node, "cover") && attr(node, "data-src");
  });
  if (coverNode) cover = fixUrl(attr(coverNode, "data-src"));
  if (!cover) {
    var anyImage = first(root, function (node) { return node.tag === "img" && attr(node, "data-src"); });
    if (anyImage) cover = fixUrl(attr(anyImage, "data-src"));
  }

  function hidden(id) {
    var node = first(root, function (item) {
      return item.tag === "input" && attr(item, "id") === id;
    });
    return node ? trim(attr(node, "value")) : "";
  }
  var currentId = hidden("current_id") || sourceId;
  var token = hidden("e_token");
  var mType = hidden("mtype") || "1";
  if (!currentId || !token) throw new Error("爱看机器人缺少播放令牌，请刷新页面重试");

  var metas = findAll(root, function (node) { return hasClass(node, "meta") && node.tag === "h3"; });
  var texts = [];
  for (var i = 0; i < metas.length; i++) {
    var value = clean(nodeText(metas[i]));
    if (value) texts.push(value);
  }

  return {
    title: title,
    cover: cover,
    desc: texts.join(" · "),
    currentId: currentId,
    token: token,
    mType: mType,
    texts: texts,
  };
}

function categories(force) {
  return CATEGORIES;
}

function catalogPage(page, category) {
  var current = page > 0 ? page : 1;
  var cat = category == null ? "" : String(category).trim();
  if (!validCategory(cat)) throw new Error("爱看机器人内容分类无效");
  if (cat === "") cat = CATEGORIES[0].id;

  var path = current > 1 ? "/hot/index-" + cat + "-p-" + current + ".html" : "/hot/index-" + cat + ".html";
  var result = getPage(path);
  var items = parseCards(result.root, cat);
  if (items.length === 0) return { items: [], hasMore: false };
  return { items: items, hasMore: current < pageCount(result.body, current, items.length) };
}

function search(page, query) {
  var keyword = trim(query);
  if (!keyword || keyword.length > 256) return { items: [], hasMore: false };
  if (page > 1) return { items: [], hasMore: false };
  var result = getPage("/search?q=" + encodeURIComponent(keyword));
  return { items: parseSearchCards(result.root), hasMore: false };
}

function detail(sourceId) {
  var id = trim(sourceId);
  if (!numericId(id)) throw new Error("爱看机器人视频 ID 无效");
  var result = getPage("/play/" + id);
  var pageMeta = parsePlayPage(result.body, id);
  var lines = cachedLines(id, pageMeta);
  var primary = lines[0];

  var chapters = [];
  var seenOrder = {};
  for (var i = 0; i < primary.episodes.length; i++) {
    var episode = primary.episodes[i];
    var order = episode.order > 0 ? episode.order : i + 1;
    if (seenOrder[order]) continue;
    seenOrder[order] = true;
    var title = episode.name || ("第 " + order + " 集");
    chapters.push({
      id: host.chapterId(id, String(order)),
      source: host.source,
      title: title.slice(0, 128),
      currentEpisode: order,
      videoUrl: episode.url,
      pageUrl: BASE + "/play/" + id,
      referer: BASE + "/",
    });
  }
  chapters.sort(function (a, b) {
    return (Number(a.currentEpisode) || 0) - (Number(b.currentEpisode) || 0);
  });
  if (chapters.length === 0) throw new Error("爱看机器人暂无可播放分集");

  var tags = [];
  var year = "";
  var texts = pageMeta.texts || [];
  for (var j = 0; j < texts.length; j++) {
    if (!year && /^(19|20)\d{2}$/.test(texts[j])) year = texts[j];
    if (texts[j].indexOf("/") >= 0) tags.push(texts[j].slice(0, 64));
  }

  return {
    drama: {
      id: host.dramaId(id),
      source: host.source,
      sourceId: id,
      title: pageMeta.title,
      name: pageMeta.title,
      desc: pageMeta.desc.slice(0, 12000),
      intro: pageMeta.desc.slice(0, 12000),
      cover: pageMeta.cover,
      onlineDate: year,
      tags: tags,
      totalEpisode: chapters.length,
      channelName: "爱看机器人",
    },
    chapters: chapters,
  };
}

function resolveMedia(task) {
  var dramaId = String(task.dramaId || "");
  var split = dramaId.indexOf(":");
  var sourceId = split > 0 ? dramaId.slice(split + 1) : dramaId;
  if (!numericId(sourceId)) throw new Error("爱看机器人播放分集信息无效，请刷新详情");

  var chapter = task.chapter || {};
  var chapterId = String(chapter.id || "");
  var prefix = host.source + ":" + sourceId + ":";
  if (chapterId.indexOf(prefix) !== 0) throw new Error("爱看机器人播放分集信息无效，请刷新详情");
  var payload = chapterId.slice(prefix.length);
  var referer = trim(chapter.referer) || BASE + "/";

  var options = [];
  var seen = {};
  var order = Number(payload);
  if (order > 0 && order <= 100000 && isFinite(order)) {
    var lines = cachedLines(sourceId, null);
    for (var i = 0; i < lines.length; i++) {
      var episode = lineEpisode(lines[i], order);
      if (!episode || seen[episode.url]) continue;
      seen[episode.url] = true;
      options.push({
        url: episode.url,
        referer: referer,
        quality: lineQuality(lines[i].flag),
      });
    }
  }

  // 兜底：旧格式分集 ID 直接存地址，或线路接口临时失败时用详情地址
  if (options.length === 0) {
    var direct = fixMediaUrl(payload) || fixMediaUrl(chapter.videoUrl);
    if (direct) options.push({ url: direct, referer: referer });
  }
  if (options.length === 0) throw new Error("爱看机器人该集没有可用线路，请刷新详情");

  // 注意：根对象必须新建，不能直接用 options[0] 再把 options 挂回它的 variants，
  // 否则 media.variants[0] === media 形成循环引用，宿主序列化时报错。
  var primary = options[0];
  var media = { url: primary.url, referer: primary.referer };
  media.variants = options.slice();
  return media;
}


    return { categories: categories, validCategory: validCategory, catalogPage: catalogPage,
             search: search, detail: detail, resolveMedia: resolveMedia };
  })(compatHost);

  // ---- idj1 协议适配 ----
  function toItems(list) {
    return (list || []).map(function (d) {
      return {
        id: d.id || d.sourceId || '',
        title: d.title || d.name || '',
        cover: d.cover || '',
        remarks: d.categoryName || d.channelName || ''
      };
    });
  }

  function home() {
    var cats = IK.categories().map(function (c) { return { id: c.id, name: c.name }; });
    var first = IK.catalogPage(1, cats.length ? cats[0].id : '');
    return { categories: cats, items: toItems(first.items), hasMore: !!first.hasMore };
  }

  function category(a) {
    var r = IK.catalogPage(a.page || 1, a.id || '');
    return { items: toItems(r.items), hasMore: !!r.hasMore };
  }

  function search(a) {
    var r = IK.search(a.page || 1, a.keyword || '');
    return { items: toItems(r.items), hasMore: !!r.hasMore };
  }

  function detail(a) {
    var sid = String(a.id || '').replace(/^ikanbot:/, '');
    var raw = IK.detail(sid);
    var drama = raw.drama || {};
    var chapters = raw.chapters || [];
    var episodes = chapters.map(function (c) {
      return { id: c.id, name: c.title || (c.currentEpisode ? '第' + c.currentEpisode + '集' : '') };
    });
    var tagList = (drama.tags || []).slice();
    if (drama.onlineDate) tagList.unshift(String(drama.onlineDate));
    return {
      title: drama.title || '',
      cover: drama.cover || '',
      desc: drama.desc || '',
      tags: tagList,
      lines: [{ name: '默认', episodes: episodes }]
    };
  }

  function play(a) {
    var episodeId = String(a.episodeId || '');
    var dramaId = '';
    var sourceId = '';
    var order = '';
    // episodeId 形如 ikanbot:<sourceId>:<order>
    var parts = episodeId.split(':');
    if (parts.length >= 3 && parts[0] === IK_SOURCE) {
      sourceId = parts[1]; order = parts[2];
      dramaId = IK_SOURCE + ':' + sourceId;
    } else if (a.id) {
      sourceId = String(a.id).replace(/^ikanbot:/, '');
      dramaId = IK_SOURCE + ':' + sourceId;
    }
    var chapter = { id: episodeId, referer: 'https://www1.ikanbot.com/' };
    var media = IK.resolveMedia({ dramaId: dramaId, chapter: chapter });
    var variants = (media && media.variants) || [media];
    var streams = (variants || []).map(function (v) {
      var url = String((v && v.url) || '');
      var name = (v && v.quality) || '';
      return { url: url, name: name, format: /\.m3u8/.test(url) ? 'hls' : 'mp4',
               headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36', 'Referer': (v && v.referer) || 'https://www1.ikanbot.com/' } };
    }).filter(function (s) { return /^https:\/\//.test(s.url); });
    if (!streams.length) throw host.error('E_NOT_FOUND', '没有可用播放线路');
    return { streams: streams };
  }

  return { home: home, category: category, search: search, detail: detail, play: play };
})();

export default _plugin;
