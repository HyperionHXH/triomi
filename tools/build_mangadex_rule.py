"""Generate the shipped MangaDex rule from reviewable JavaScript."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = r"""
function firstTitle(a) {
  var t = (a && a.title) || {};
  if (t.zh || t['zh-hk'] || t['zh-cn']) return t.zh || t['zh-hk'] || t['zh-cn'];
  var alt = (a && a.altTitles) || [];
  for (var i = 0; i < alt.length; i++) {
    var c = alt[i];
    if (c.zh || c['zh-hk'] || c['zh-cn']) return c.zh || c['zh-hk'] || c['zh-cn'];
  }
  return t.en || Object.values(t)[0] || '未命名';
}
function cover(id, relationships) {
  for (var i = 0; i < (relationships || []).length; i++) {
    var r = relationships[i];
    if (r.type === 'cover_art' && r.attributes && r.attributes.fileName)
      return 'https://uploads.mangadex.org/covers/' + id + '/' + r.attributes.fileName + '.256.jpg';
  }
  return '';
}
function toItem(node) {
  var a = node.attributes || {};
  var desc = a.description || {};
  return {remoteId: node.id, title: firstTitle(a), url: '/manga/' + node.id,
    coverUrl: cover(node.id, node.relationships),
    description: desc.zh || desc['zh-hk'] || desc.en || '', status: a.status || '',
    tags: (a.tags || []).map(function(t) {var n = (t.attributes || {}).name || {}; return n.zh || n.en || '';}).filter(Boolean)};
}
async function api(url) {
  var res = await triomi.fetch(/^https?:\/\//i.test(url) ? url : triomi.baseUrl + url);
  if (res.status < 200 || res.status >= 300) throw new Error('MangaDex HTTP ' + res.status);
  var data = JSON.parse(res.body);
  if (!data || data.result === 'error') throw new Error('MangaDex 未能返回可用内容，请重试或选择其他章节');
  return data;
}
async function discover(url, page) {
  var data = await api(url);
  if (!Array.isArray(data.data)) throw new Error('MangaDex 作品列表格式不完整');
  return data.data.map(toItem);
}
async function search(keyword, page) {
  var url = '/manga?limit=20&offset=' + ((page - 1) * 20) +
    '&includes[]=cover_art&availableTranslatedLanguage[]=zh&availableTranslatedLanguage[]=zh-hk&title=' + encodeURIComponent(keyword);
  return discover(url, page);
}
async function searchTags() {
  var data = await api('/manga/tag');
  if (!Array.isArray(data.data)) throw new Error('MangaDex 标签列表格式不完整');
  return data.data.map(function(t) {
    var names = (t.attributes || {}).name || {};
    return {id: t.id, label: names.zh || names.en || ''};
  }).filter(function(t) {return t.id && t.label;});
}
async function searchTagged(keyword, page, tags) {
  var taxonomy = await searchTags();
  var url = '/manga?limit=20&offset=' + ((page - 1) * 20) +
    '&includes[]=cover_art&availableTranslatedLanguage[]=zh&availableTranslatedLanguage[]=zh-hk' +
    '&includedTagsMode=AND&title=' + encodeURIComponent(keyword);
  for (var i = 0; i < tags.length; i++) {
    var selected = taxonomy.find(function(t) {return t.id === tags[i] || t.label === tags[i];});
    if (!selected) throw new Error('MangaDex 没有此标签：' + tags[i]);
    url += '&includedTags[]=' + encodeURIComponent(selected.id);
  }
  return discover(url, page);
}
async function detail(url, item) {
  var id = (item && item.remoteId) || url.split('/').pop();
  var data = await api('/manga/' + id + '?includes[]=cover_art');
  if (!data.data || !data.data.id) throw new Error('MangaDex 作品详情格式不完整');
  var out = [], seen = {}, offset = 0;
  for (var page = 0; page < 100; page++) {
    var result = await api('/manga/' + id + '/feed?limit=100&offset=' + offset +
      '&translatedLanguage[]=zh&translatedLanguage[]=zh-hk&includeExternalUrl=0&order[chapter]=asc&order[volume]=asc');
    var rows = result.data;
    if (!Array.isArray(rows)) throw new Error('MangaDex 章节目录格式不完整');
    var total = result.total;
    if (typeof total === 'number' && total > 10000) throw new Error('中文目录超过 10000 章上限，未保存不完整目录');
    if (rows.length === 0) {
      if (typeof total === 'number' && offset < total) throw new Error('MangaDex 目录提前中断，请重新加载');
      return {item: toItem(data.data), chapters: out};
    }
    var added = 0;
    for (var i = 0; i < rows.length; i++) {
      var c = rows[i], a = c.attributes;
      if (!c.id || !a) throw new Error('MangaDex 章节缺少身份或属性');
      if (seen[c.id]) continue;
      seen[c.id] = true;
      added++;
      var number = a.chapter;
      out.push({remoteId: c.id,
        title: (number ? '第 ' + number + ' 话' : a.title || '章节 ' + (out.length + 1)) +
          (a.translatedLanguage === 'zh-hk' ? ' · 繁中' : ''),
        url: '/chapter/' + c.id, number: number || (out.length + 1), releaseDate: a.publishAt || ''});
    }
    if (!added) throw new Error('MangaDex 重复返回同一页，未保存不完整目录');
    offset += rows.length;
    if (typeof total === 'number' ? offset >= total : rows.length < 100)
      return {item: toItem(data.data), chapters: out};
  }
  throw new Error('中文目录达到 100 页上限，未保存不完整目录');
}
async function content(url, chapter, options) {
  var id = chapter.remoteId || url.split('/').pop();
  var data = await api('/at-home/server/' + id);
  var base = data.baseUrl, c = data.chapter || {};
  var saver = options && options.dataSaver === true && Array.isArray(c.dataSaver) && c.dataSaver.length > 0;
  var full = !saver && Array.isArray(c.data) && c.data.length > 0;
  var files = full ? c.data : c.dataSaver;
  if (typeof base !== 'string' || !/^https:\/\//i.test(base) || !c.hash ||
      !Array.isArray(files) || !files.length || files.some(function(f) {return typeof f !== 'string' || !f;}))
    throw new Error('本章未提供可用的应用内图片（可能仅在外站托管），请返回目录选择其他章节或重试');
  var path = full ? 'data' : 'data-saver';
  return {images: files.map(function(f) {return base.replace(/\/$/, '') + '/' + path + '/' + c.hash + '/' + f;})};
}
""".strip()


def main():
    path = ROOT / 'assets/rules/mangadex-api-js.json'
    rule = json.loads(path.read_text(encoding='utf-8'))
    rule['version'] = '1.0.5'
    for feed in rule['feeds']:
        feed['url'] = feed['url'].replace(
            'availableTranslatedLanguage[]=zh&',
            'availableTranslatedLanguage[]=zh&availableTranslatedLanguage[]=zh-hk&',
        ) if 'availableTranslatedLanguage[]=zh-hk' not in feed['url'] else feed['url']
    rule['script'] = SCRIPT
    path.write_text(json.dumps(rule, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    catalog_path = ROOT / 'assets/catalog/index.json'
    catalog = json.loads(catalog_path.read_text(encoding='utf-8'))
    for entry in catalog['sources']:
        if entry['id'] == 'mangadex':
            entry['version'] = '1.0.5'
    catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
