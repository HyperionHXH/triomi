"""Generate our own Triomi rule against the public site used by Kazumi's AGE rule."""
import json
from pathlib import Path

script = r'''
var ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36';
async function fetchPage(url) {
  var r = await triomi.fetch(url, {headers: {'User-Agent': ua}});
  return r.body;
}
function secure(url) { return (url || '').replace(/^http:\/\/www\.agedm\.io/, 'https://www.agedm.io'); }
async function list(html) {
  var rows = await triomi.select(html, '.video_item', {
    title: '.video_item-title a', url: {selector: '.video_item-title a', attr: 'href', absolute: true},
    coverUrl: {selector: 'img', attr: 'data-original', absolute: true}
  });
  if (!rows.length) rows = await triomi.select(html, '.cata_video_item', {
    title: 'h5 a', url: {selector: 'h5 a', attr: 'href', absolute: true},
    coverUrl: {selector: 'img', attr: 'data-original', absolute: true}
  });
  var seen={},out=[];
  for(var i=0;i<rows.length;i++) {
    var r=rows[i],m=/\/detail\/(\d+)/.exec(r.url || '');
    if(!m || seen[m[1]] || !r.title) continue;
    seen[m[1]]=true; r.remoteId=m[1];r.url=secure(r.url);out.push(r);
  }
  return out;
}
async function discover(url,page) { if(page>1)return [];return list(await fetchPage(url)); }
async function search(keyword,page) {
  if(page>1)return [];
  return list(await fetchPage(triomi.baseUrl+'/search?query='+encodeURIComponent(keyword)));
}
async function detail(url,item) {
  var html=await fetchPage(secure(url));
  var rows=await triomi.select(html, 'ul.video_detail_episode a', {
    title:'.',url:{selector:'.',attr:'href',absolute:true}
  });
  var chapters=[];
  for(var i=0;i<rows.length;i++) {
    var r=rows[i],m=/\/play\/(\d+)\/(\d+)\/(\d+)/.exec(r.url || '');
    if(!m)continue;
    r.remoteId=m[1]+'/'+m[2]+'/'+m[3];r.url=secure(r.url);
    r.title='线路 '+m[2]+' · '+r.title;r.volumeTitle='线路 '+m[2];r.number=Number(m[3]);chapters.push(r);
  }
  return {item:{title:item.title,description:await triomi.value(html,'.video_detail_desc')},chapters:chapters};
}
async function content(url,chapter) {
  var html=await fetchPage(secure(url));
  var iframe=await triomi.value(html,'#iframeForVideo','src');
  if(!iframe)throw new Error('播放页结构已变化，未找到播放器');
  return {playSources:[{name:chapter.title,url:iframe,webPage:true,
    unavailableVideoUrls:['https://kjjsaas-sh.oss-cn-shanghai.aliyuncs.com/u/3401405881/20240818-936952-fc31b16575e80a7562cdb1f81a39c6b0.mp4'],
    headers:{'User-Agent':ua,'Referer':secure(url)}}]};
}
'''

rule = dict(id='age-anime', name='AGE 番剧', type='anime', engine='js', lang='zh',
            version='1.0.1', baseUrl='https://www.agedm.io', requireLogin=False,
            feeds=[dict(id='latest', name='最新番剧', url='/')], script=script)
root = Path(__file__).resolve().parents[1]
(root/'assets/rules/age-anime-js.json').write_text(json.dumps(rule,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
