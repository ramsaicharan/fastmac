"""fastmac report — self-contained HTML viewer. No CDN, no network."""
from __future__ import annotations
import html, json, time

CSS = r"""
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0e1116; --panel:#151a21; --panel2:#1b222b; --line:#252d38;
  --ink:#e6edf3; --dim:#8b97a6; --faint:#5a6675;
  --accent:#4c9aff; --good:#3fb950; --warn:#d29922; --bad:#f85149;
}
body{background:var(--bg);color:var(--ink);font:13px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",Segoe UI,sans-serif;
     height:100vh;overflow:hidden;display:flex;flex-direction:column}
header{display:flex;align-items:center;gap:16px;padding:10px 16px;background:var(--panel);
       border-bottom:1px solid var(--line);flex-shrink:0}
header h1{font-size:14px;font-weight:600;letter-spacing:.2px}
header .root{color:var(--dim);font-size:12px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
header .stats{margin-left:auto;color:var(--dim);font-size:12px;display:flex;gap:18px}
header .stats b{color:var(--ink);font-weight:600}
nav{display:flex;gap:2px;padding:0 12px;background:var(--panel);border-bottom:1px solid var(--line);flex-shrink:0;overflow-x:auto}
nav button{background:none;border:none;color:var(--dim);padding:9px 13px;font-size:12.5px;cursor:pointer;
           border-bottom:2px solid transparent;white-space:nowrap;font-family:inherit}
nav button:hover{color:var(--ink)}
nav button.on{color:var(--accent);border-bottom-color:var(--accent)}
main{flex:1;display:flex;min-height:0}
#stage{flex:1;position:relative;overflow:auto;min-width:0}
#side{width:310px;border-left:1px solid var(--line);background:var(--panel);overflow-y:auto;flex-shrink:0;padding:14px}
#crumbs{padding:7px 16px;background:var(--panel2);border-bottom:1px solid var(--line);font-size:12px;
        display:flex;gap:6px;align-items:center;flex-wrap:wrap;flex-shrink:0;min-height:32px}
#crumbs a{color:var(--accent);cursor:pointer;text-decoration:none}
#crumbs a:hover{text-decoration:underline}
#crumbs span{color:var(--faint)}
svg{display:block}
.node{cursor:pointer}
.node:hover{filter:brightness(1.35)}
.lbl{font-size:10.5px;fill:#fff;pointer-events:none;font-family:inherit}
.lbl.dark{fill:#0b0e13}
h3{font-size:11px;text-transform:uppercase;letter-spacing:.7px;color:var(--faint);margin:16px 0 8px;font-weight:600}
h3:first-child{margin-top:0}
.kv{display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid var(--line);font-size:12px;gap:10px}
.kv span:first-child{color:var(--dim);flex-shrink:0}
.kv span:last-child{text-align:right;word-break:break-word;font-variant-numeric:tabular-nums}
.path{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;color:var(--dim);
      word-break:break-all;background:var(--panel2);padding:7px;border-radius:5px;margin-bottom:10px;line-height:1.45}
.rows{display:flex;flex-direction:column}
.row{display:flex;align-items:center;gap:10px;padding:6px 8px;border-radius:5px;cursor:pointer;position:relative}
.row:hover{background:var(--panel2)}
.row .bar{position:absolute;left:0;top:0;bottom:0;background:var(--accent);opacity:.14;border-radius:5px}
.row .nm{flex:1;position:relative;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row .sz{position:relative;color:var(--dim);font-variant-numeric:tabular-nums;font-size:12px;flex-shrink:0}
.row .pct{position:relative;color:var(--faint);font-size:11px;width:42px;text-align:right;flex-shrink:0}
.dirmark{color:var(--accent);flex-shrink:0;position:relative}
.filemark{color:var(--faint);flex-shrink:0;position:relative}
button.act{background:var(--panel2);border:1px solid var(--line);color:var(--ink);padding:7px 11px;
           border-radius:6px;cursor:pointer;font-size:12px;width:100%;margin-top:7px;font-family:inherit}
button.act:hover{border-color:var(--accent);color:var(--accent)}
button.act.danger:hover{border-color:var(--bad);color:var(--bad)}
.pill{display:inline-block;padding:1.5px 7px;border-radius:10px;font-size:10.5px;font-weight:600}
.pill.safe{background:rgba(63,185,80,.16);color:var(--good)}
.pill.review{background:rgba(210,153,34,.16);color:var(--warn)}
.pane{padding:16px;display:none}
.pane.on{display:block}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;color:var(--faint);font-size:11px;text-transform:uppercase;letter-spacing:.5px;
   padding:7px 9px;border-bottom:1px solid var(--line);font-weight:600;position:sticky;top:0;background:var(--bg)}
td{padding:6px 9px;border-bottom:1px solid var(--line)}
tr:hover td{background:var(--panel2)}
td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
td.p{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;color:var(--dim);
     max-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.agebar{height:26px;display:flex;border-radius:4px;overflow:hidden;margin:10px 0}
.agebar div{transition:opacity .15s}
.agebar div:hover{opacity:.75}
.legend{display:flex;flex-wrap:wrap;gap:14px;font-size:11.5px;color:var(--dim);margin-top:8px}
.legend i{display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px}
.tip{position:fixed;background:#000;border:1px solid var(--line);padding:7px 10px;border-radius:6px;
     font-size:11.5px;pointer-events:none;z-index:99;display:none;max-width:420px;line-height:1.5}
.tip b{color:var(--accent)}
.empty{color:var(--faint);padding:36px;text-align:center;font-size:13px}
.grp{border:1px solid var(--line);border-radius:7px;margin-bottom:9px;overflow:hidden}
.grp>div:first-child{background:var(--panel2);padding:8px 11px;font-size:12px;display:flex;
                     justify-content:space-between;align-items:center}
.grp ul{list-style:none;padding:5px 11px 9px}
.grp li{font-family:ui-monospace,Menlo,monospace;font-size:11px;color:var(--dim);padding:3px 0;
        display:flex;gap:9px;align-items:center}
.grp li span{flex:1;word-break:break-all}
.grp li button{background:none;border:1px solid var(--line);color:var(--faint);border-radius:4px;
               padding:1px 7px;cursor:pointer;font-size:10px;flex-shrink:0;font-family:inherit}
.grp li button:hover{border-color:var(--bad);color:var(--bad)}
#qcount{background:var(--accent);color:#04101f;border-radius:9px;padding:0 6px;font-size:10.5px;
        font-weight:700;margin-left:5px}
.hint{color:var(--faint);font-size:11.5px;margin-bottom:12px;line-height:1.5}
/* multi-select */
.row.pick,tr.pick td{background:rgba(76,154,255,.14)!important}
.node.pick rect,.node.pick path,.node.pick circle{stroke:#fff!important;stroke-width:2.2!important}
.ck{width:13px;height:13px;border:1.5px solid var(--line);border-radius:3px;flex-shrink:0;
    position:relative;cursor:pointer;display:inline-block;vertical-align:-2px}
.ck.on{background:var(--accent);border-color:var(--accent)}
.ck.on:after{content:"";position:absolute;left:3.5px;top:.5px;width:4px;height:8px;
  border:solid #04101f;border-width:0 2px 2px 0;transform:rotate(42deg)}
#selbar{position:fixed;left:50%;transform:translateX(-50%);bottom:-70px;background:var(--panel2);
  border:1px solid var(--line);border-radius:10px;padding:9px 14px;display:flex;gap:11px;
  align-items:center;z-index:60;box-shadow:0 8px 28px rgba(0,0,0,.55);transition:bottom .18s}
#selbar.up{bottom:18px}
#selbar b{font-variant-numeric:tabular-nums}
#selbar button{background:var(--accent);color:#04101f;border:none;padding:6px 13px;border-radius:6px;
  font-size:12px;font-weight:600;cursor:pointer;font-family:inherit}
#selbar button.ghost{background:none;color:var(--dim);border:1px solid var(--line);font-weight:400}
#selbar button.ghost:hover{color:var(--ink)}
/* live badge */
.live{display:inline-flex;align-items:center;gap:5px;font-size:11px;color:var(--good)}
.live i{width:6px;height:6px;border-radius:50%;background:var(--good);animation:pulse 1.9s infinite}
.live.off{color:var(--faint)} .live.off i{background:var(--faint);animation:none}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.28}}
/* memory */
.mgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(168px,1fr));gap:11px;margin-bottom:18px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:13px}
.card .lab{font-size:10.5px;text-transform:uppercase;letter-spacing:.6px;color:var(--faint);font-weight:600}
.card .big{font-size:23px;font-weight:600;margin-top:5px;font-variant-numeric:tabular-nums}
.card .sub{font-size:11.5px;color:var(--dim);margin-top:3px}
.stack{height:34px;display:flex;border-radius:6px;overflow:hidden;margin:12px 0 7px}
.stack div{position:relative;transition:width .45s ease}
.verdict{padding:9px 13px;border-radius:8px;font-size:12.5px;margin-bottom:15px;border:1px solid}
.verdict.good{background:rgba(63,185,80,.09);border-color:rgba(63,185,80,.34);color:var(--good)}
.verdict.warn{background:rgba(210,153,34,.09);border-color:rgba(210,153,34,.34);color:var(--warn)}
.verdict.bad{background:rgba(248,81,73,.09);border-color:rgba(248,81,73,.34);color:var(--bad)}
.pbar{height:6px;background:var(--panel2);border-radius:3px;overflow:hidden;margin-top:7px}
.pbar div{height:100%;border-radius:3px;transition:width .45s}
"""

JS = r"""
const fmt=b=>{const u=['B','KB','MB','GB','TB'];let i=0,n=Math.abs(b);
  while(n>=1024&&i<4){n/=1024;i++}return (i<2?n.toFixed(0):n.toFixed(1))+' '+u[i]};
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const base=p=>p.split('/').filter(Boolean).pop()||p;
const shellQuote=s=>"\'"+String(s).replace(/'/g,"'\\''")+"\'";
const days=t=>Math.floor((Date.now()/1000-t)/86400);
const tip=document.getElementById('tip');
function showTip(e,html){tip.innerHTML=html;tip.style.display='block';
  const r=tip.getBoundingClientRect();
  let x=e.clientX+14,y=e.clientY+14;
  if(x+r.width>innerWidth-10)x=e.clientX-r.width-14;
  if(y+r.height>innerHeight-10)y=e.clientY-r.height-14;
  tip.style.left=x+'px';tip.style.top=y+'px'}
function hideTip(){tip.style.display='none'}

/* colour: stable hue per name, lightness by depth */
function hue(s){let h=0;for(let i=0;i<s.length;i++)h=(h*31+s.charCodeAt(i))|0;return Math.abs(h)%360}
function col(n,d){const h=hue(n.n||'');return `hsl(${h} 52% ${Math.max(26,60-d*6)}%)`}
function lum(n,d){return (60-d*6)>52}

let ROOT=DATA.tree, CUR=DATA.tree, VIEW='folders';
const stack=[];

/* ── live mode: token arrives in the URL fragment, which never hits the wire ── */
/* The token arrives in the fragment (never sent to the server, never logged). We strip it
   from the address bar but keep it in sessionStorage, so a reload doesn't silently drop
   live mode — and it dies with the tab rather than persisting to disk. */
const TOKEN=(()=>{
  const fromHash=(location.hash.match(/t=([\w\-]+)/)||[])[1];
  if(fromHash){try{sessionStorage.setItem('fastmac.token',fromHash)}catch(e){}
               history.replaceState(null,'',location.pathname);return fromHash}
  try{return sessionStorage.getItem('fastmac.token')||''}catch(e){return ''}
})();
const LIVE=LIVE_MODE&&!!TOKEN;

async function api(path,body,signal){
  if(!LIVE)throw new Error('read-only');
  const r=await fetch(path,{method:body?'POST':'GET',
    headers:{'X-Fastmac-Token':TOKEN,'Content-Type':'application/json'},
    body:body?JSON.stringify(body):undefined,signal});
  if(!r.ok)throw new Error((await r.json().catch(()=>({}))).error||r.statusText);
  return r.json();
}

/* ── multi-selection ─────────────────────────────────────────────── */
const PICK=new Map();                 /* path -> bytes */
function picked(p){return PICK.has(p)}
function togglePick(p,sz){
  if(!p)return;
  PICK.has(p)?PICK.delete(p):PICK.set(p,sz||0);
  selbar();draw();
}
function clearPick(){PICK.clear();selbar();draw()}
function selbar(){
  const bar=document.getElementById('selbar');
  const n=PICK.size,tot=[...PICK.values()].reduce((a,b)=>a+b,0);
  document.getElementById('selinfo').textContent=
    `${n} selected · ${fmt(tot)}`;
  bar.classList.toggle('up',n>0);
}

/* ── layout: partition (sunburst + flame) ───────────────────── */
function partition(node,depth,x0,x1,out,maxd){
  out.push({node,depth,x0,x1});
  if(depth>=maxd)return;
  const kids=node.c||[];const tot=kids.reduce((s,k)=>s+k.s,0)||1;
  let x=x0;const span=x1-x0;
  for(const k of kids){const w=span*k.s/tot;
    if(w>span*0.002)partition(k,depth+1,x,x+w,out,maxd);x+=w}
}

/* ── layout: squarified treemap ─────────────────────────────── */
function squarify(kids,x,y,w,h){
  const out=[];const tot=kids.reduce((s,k)=>s+k.s,0);if(!tot||w<=0||h<=0)return out;
  const items=kids.map(k=>({k,a:k.s/tot*w*h}));
  let i=0;
  while(i<items.length){
    const horiz=w>=h;const len=horiz?h:w;
    let row=[items[i]],sum=items[i].a,best=worst(row,sum,len);i++;
    while(i<items.length){
      const s2=sum+items[i].a,r2=worst([...row,items[i]],s2,len);
      if(r2<best)break;              /* adding this one makes the row worse — close it */
      row.push(items[i]);sum=s2;best=r2;i++;
    }
    const thick=sum/len;let off=horiz?y:x;
    for(const it of row){
      const side=it.a/thick;
      if(horiz)out.push({k:it.k,x,y:off,w:thick,h:side});
      else     out.push({k:it.k,x:off,y,w:side,h:thick});
      off+=side;
    }
    if(horiz){x+=thick;w-=thick}else{y+=thick;h-=thick}
  }
  return out;
  function worst(row,sum,len){
    const side=sum/len;let mn=Infinity,mx=0;
    for(const r of row){const o=r.a/side;if(o<mn)mn=o;if(o>mx)mx=o}
    return Math.min(side/mx,mn/side);
  }
}

/* ── layout: circle packing (deterministic spiral) ──────────── */
function packCircles(kids,R){
  const tot=kids.reduce((s,k)=>s+k.s,0)||1;
  const items=kids.map(k=>({k,r:Math.sqrt(k.s/tot)*R*0.83})).sort((a,b)=>b.r-a.r);
  const placed=[];
  for(const it of items){
    if(!placed.length){it.x=0;it.y=0;placed.push(it);continue}
    let done=false;
    for(let rad=it.r*0.4;rad<R*2.4&&!done;rad+=Math.max(1.2,it.r*0.16)){
      const steps=Math.max(14,Math.floor(rad*1.1));
      for(let s=0;s<steps;s++){
        const a=s/steps*Math.PI*2+rad*0.37;
        const x=Math.cos(a)*rad,y=Math.sin(a)*rad;
        if(Math.hypot(x,y)+it.r>R)continue;
        let hit=false;
        for(const p of placed){if(Math.hypot(x-p.x,y-p.y)<it.r+p.r+1.1){hit=true;break}}
        if(!hit){it.x=x;it.y=y;placed.push(it);done=true;break}
      }
    }
  }
  return placed.filter(p=>p.x!==undefined&&p.r>1.2);
}

/* ── layout: tidy tree (mind map) ───────────────────────────── */
function tidyTree(node,maxd){
  const nodes=[],links=[];let leaf=0;
  (function walk(n,d,parent){
    const me={n,d,parent,y:0};
    const kids=(d<maxd?(n.c||[]):[]).filter(k=>!k.other).slice(0,9);
    if(!kids.length){me.y=leaf++}
    else{
      const ys=kids.map(k=>walk(k,d+1,me).y);
      me.y=(Math.min(...ys)+Math.max(...ys))/2;
    }
    nodes.push(me);
    if(parent)links.push({a:parent,b:me});
    return me;
  })(node,0,null);
  return{nodes,links,leaves:Math.max(1,leaf)};
}

/* ─────────────────────────── renderers ──────────────────────── */
const stage=document.getElementById('stage');

function nodeEvents(el,n,extra){
  el.addEventListener('mousemove',e=>showTip(e,
    `<b>${esc(n.n)}</b><br>${fmt(n.s)}${n.f?` · ${n.f.toLocaleString()} files`:''}${extra||''}`));
  el.addEventListener('mouseleave',hideTip);
  el.addEventListener('click',e=>{hideTip();
    if(e.metaKey||e.ctrlKey||e.shiftKey){e.stopPropagation();return togglePick(n.p,n.s)}
    select(n);if(n.c&&!n.other)drill(n)});
  if(picked(n.p))el.classList.add('pick');
}

function svgEl(w,h){
  const s=document.createElementNS('http://www.w3.org/2000/svg','svg');
  s.setAttribute('width',w);s.setAttribute('height',h);
  s.setAttribute('viewBox',`0 0 ${w} ${h}`);return s;
}
function mk(t,attrs){const e=document.createElementNS('http://www.w3.org/2000/svg',t);
  for(const k in attrs)e.setAttribute(k,attrs[k]);return e}

function renderTreemap(){
  const W=stage.clientWidth-32,H=stage.clientHeight-32;
  const kids=(CUR.c||[]).filter(k=>k.s>0);
  if(!kids.length)return empty('Nothing inside this folder.');
  const svg=svgEl(W,H);
  for(const r of squarify(kids,0,0,W,H)){
    if(r.w<1.5||r.h<1.5)continue;
    const g=mk('g',{class:'node'});
    g.appendChild(mk('rect',{x:r.x+1,y:r.y+1,width:Math.max(0,r.w-2),height:Math.max(0,r.h-2),
      rx:3,fill:col(r.k,1),stroke:'#0e1116','stroke-width':1}));
    if(r.w>58&&r.h>24){
      const t=mk('text',{x:r.x+7,y:r.y+16,class:'lbl'+(lum(r.k,1)?' dark':'')});
      t.textContent=r.k.n.slice(0,Math.floor(r.w/6.6));g.appendChild(t);
      if(r.h>40){const t2=mk('text',{x:r.x+7,y:r.y+31,class:'lbl'+(lum(r.k,1)?' dark':''),opacity:.75});
        t2.textContent=fmt(r.k.s);g.appendChild(t2)}
    }
    nodeEvents(g,r.k);svg.appendChild(g);
  }
  paint(svg);
}

function renderSunburst(){
  const W=stage.clientWidth-32,H=stage.clientHeight-32;
  const R=Math.min(W,H)/2-8,cx=W/2,cy=H/2,MAXD=7;
  const parts=[];partition(CUR,0,0,1,parts,MAXD);
  const svg=svgEl(W,H);const ring=R/(MAXD+1);
  for(const p of parts){
    if(p.depth===0)continue;
    const r0=p.depth*ring,r1=r0+ring-1.4;
    const a0=p.x0*Math.PI*2-Math.PI/2,a1=p.x1*Math.PI*2-Math.PI/2;
    if(a1-a0<0.004)continue;
    const large=(a1-a0)>Math.PI?1:0;
    const d=`M${cx+r0*Math.cos(a0)} ${cy+r0*Math.sin(a0)}`
      +`A${r0} ${r0} 0 ${large} 1 ${cx+r0*Math.cos(a1)} ${cy+r0*Math.sin(a1)}`
      +`L${cx+r1*Math.cos(a1)} ${cy+r1*Math.sin(a1)}`
      +`A${r1} ${r1} 0 ${large} 0 ${cx+r1*Math.cos(a0)} ${cy+r1*Math.sin(a0)}Z`;
    const g=mk('g',{class:'node'});
    g.appendChild(mk('path',{d,fill:col(p.node,p.depth),stroke:'#0e1116','stroke-width':.6}));
    nodeEvents(g,p.node);svg.appendChild(g);
  }
  const c=mk('circle',{cx,cy,r:ring-2,fill:'var(--panel2)',stroke:'var(--line)',class:'node'});
  c.addEventListener('click',()=>up());svg.appendChild(c);
  const t1=mk('text',{x:cx,y:cy-3,'text-anchor':'middle',class:'lbl'});
  t1.textContent=CUR.n.slice(0,16);svg.appendChild(t1);
  const t2=mk('text',{x:cx,y:cy+12,'text-anchor':'middle',class:'lbl',opacity:.7});
  t2.textContent=fmt(CUR.s);svg.appendChild(t2);
  paint(svg);
}

function renderFlame(){
  const W=stage.clientWidth-32,MAXD=15,RH=21;
  const parts=[];partition(CUR,0,0,1,parts,MAXD);
  const maxd=Math.max(...parts.map(p=>p.depth));
  const H=Math.max(stage.clientHeight-32,(maxd+1)*RH+10);
  const svg=svgEl(W,H);
  for(const p of parts){
    const x=p.x0*W,w=(p.x1-p.x0)*W;if(w<0.6)continue;
    const y=p.depth*RH;
    const g=mk('g',{class:'node'});
    g.appendChild(mk('rect',{x:x+.5,y,width:Math.max(0,w-1),height:RH-1.6,rx:2,
      fill:col(p.node,p.depth),stroke:'#0e1116','stroke-width':.4}));
    if(w>46){const t=mk('text',{x:x+5,y:y+14,class:'lbl'+(lum(p.node,p.depth)?' dark':'')});
      t.textContent=p.node.n.slice(0,Math.floor(w/6.4));g.appendChild(t)}
    nodeEvents(g,p.node);svg.appendChild(g);
  }
  paint(svg);
}

function renderBubbles(){
  const W=stage.clientWidth-32,H=stage.clientHeight-32;
  const R=Math.min(W,H)/2-10,cx=W/2,cy=H/2;
  const kids=(CUR.c||[]).filter(k=>k.s>0);
  if(!kids.length)return empty('Nothing inside this folder.');
  const svg=svgEl(W,H);
  svg.appendChild(mk('circle',{cx,cy,r:R,fill:'none',stroke:'var(--line)','stroke-dasharray':'3 4'}));
  for(const p of packCircles(kids,R)){
    const g=mk('g',{class:'node'});
    g.appendChild(mk('circle',{cx:cx+p.x,cy:cy+p.y,r:p.r,fill:col(p.k,1),
      stroke:'#0e1116','stroke-width':1,'fill-opacity':.92}));
    /* one level of nesting inside big bubbles */
    if(p.r>44&&p.k.c){
      for(const q of packCircles(p.k.c.filter(z=>z.s>0).slice(0,14),p.r*0.88)){
        if(q.r<2.5)continue;
        const g2=mk('circle',{cx:cx+p.x+q.x,cy:cy+p.y+q.y,r:q.r,fill:col(q.k,2),
          stroke:'#0e1116','stroke-width':.5,'fill-opacity':.95,class:'node'});
        nodeEvents(g2,q.k);svg.appendChild(g2);
      }
    }
    if(p.r>26){
      const t=mk('text',{x:cx+p.x,y:cy+p.y+(p.r>44?-p.r*0.55:3),'text-anchor':'middle',
        class:'lbl'+(lum(p.k,1)?' dark':'')});
      t.textContent=p.k.n.slice(0,Math.floor(p.r/3.6));svg.appendChild(t);
      if(p.r>38&&p.r<=44){const t2=mk('text',{x:cx+p.x,y:cy+p.y+16,'text-anchor':'middle',
        class:'lbl'+(lum(p.k,1)?' dark':''),opacity:.7});
        t2.textContent=fmt(p.k.s);svg.appendChild(t2)}
    }
    nodeEvents(g,p.k);svg.insertBefore(g,svg.firstChild.nextSibling);
  }
  paint(svg);
}

function renderMindmap(){
  const MAXD=4;
  const{nodes,links,leaves}=tidyTree(CUR,MAXD);
  const W=Math.max(stage.clientWidth-32,960);
  const H=Math.max(stage.clientHeight-32,leaves*26+40);
  const colw=(W-180)/(MAXD+1),rowh=(H-40)/leaves;
  const X=d=>30+d*colw, Y=y=>24+(y+0.5)*rowh;
  const svg=svgEl(W,H);
  for(const l of links){
    const x1=X(l.a.d)+94,y1=Y(l.a.y),x2=X(l.b.d),y2=Y(l.b.y),mx=(x1+x2)/2;
    svg.appendChild(mk('path',{d:`M${x1} ${y1}C${mx} ${y1} ${mx} ${y2} ${x2} ${y2}`,
      fill:'none',stroke:'var(--line)','stroke-width':1.3}));
  }
  for(const m of nodes){
    const g=mk('g',{class:'node'});
    const w=Math.max(60,Math.min(94,m.n.n.length*6.4+16));
    g.appendChild(mk('rect',{x:X(m.d),y:Y(m.y)-10,width:w,height:20,rx:5,
      fill:col(m.n,m.d),stroke:'#0e1116'}));
    const t=mk('text',{x:X(m.d)+7,y:Y(m.y)+4,class:'lbl'+(lum(m.n,m.d)?' dark':'')});
    t.textContent=m.n.n.slice(0,Math.floor(w/6.4));g.appendChild(t);
    const s=mk('text',{x:X(m.d)+w+7,y:Y(m.y)+4,class:'lbl',fill:'var(--dim)'});
    s.textContent=fmt(m.n.s);g.appendChild(s);
    nodeEvents(g,m.n);svg.appendChild(g);
  }
  paint(svg);
}

function renderFolders(){
  const kids=(CUR.c||[]);
  if(!kids.length)return empty('Nothing inside this folder.');
  const max=Math.max(...kids.map(k=>k.s))||1;
  const d=document.createElement('div');d.className='pane on';
  const rows=document.createElement('div');rows.className='rows';
  for(const k of kids){
    const r=document.createElement('div');r.className='row';
    if(picked(k.p))r.classList.add('pick');
    r.innerHTML=`<div class="bar" style="width:${k.s/max*100}%"></div>`
      +(k.other?`<span style="width:13px"></span>`:`<span class="ck${picked(k.p)?' on':''}"></span>`)
      +`<span class="${k.other?'filemark':k.c?'dirmark':'filemark'}">${k.other?'…':k.c?'▸':'·'}</span>`
      +`<span class="nm">${esc(k.n)}</span>`
      +`<span class="pct">${(k.s/CUR.s*100).toFixed(1)}%</span>`
      +`<span class="sz">${fmt(k.s)}</span>`;
    const ck=r.querySelector('.ck');
    if(ck)ck.onclick=e=>{e.stopPropagation();togglePick(k.p,k.s)};
    r.onclick=e=>{if(e.metaKey||e.ctrlKey||e.shiftKey)return togglePick(k.p,k.s);
                  select(k);if(k.c&&!k.other)drill(k)};
    rows.appendChild(r);
  }
  d.appendChild(rows);paint(d);
}

function renderTop(){
  const all=[];
  (function walk(n,d){for(const k of (n.c||[])){if(!k.other)all.push(k);if(d<9)walk(k,d+1)}})(CUR,0);
  all.sort((a,b)=>b.s-a.s);
  const rows=all.slice(0,300);
  const d=document.createElement('div');d.className='pane on';
  d.innerHTML=`<div class="hint">The 300 largest mapped folders anywhere under <b>${esc(CUR.n)}</b>. Files are included in each folder total.</div>`
    +`<table><thead><tr><th></th><th>#</th><th>Name</th><th>Path</th><th class="num">Files</th><th class="num">Size</th></tr></thead><tbody>`
    +rows.map((k,i)=>`<tr data-p="${esc(k.p)}" class="${picked(k.p)?'pick':''}">`
      +`<td><span class="ck${picked(k.p)?' on':''}" data-ck="${i}"></span></td>`
      +`<td style="color:var(--faint)">${i+1}</td>`
      +`<td>${esc(k.n)}</td><td class="p" title="${esc(k.p)}">${esc(k.p)}</td>`
      +`<td class="num" style="color:var(--dim)">${k.f?k.f.toLocaleString():'—'}</td>`
      +`<td class="num">${fmt(k.s)}</td></tr>`).join('')
    +`</tbody></table>`;
  d.querySelectorAll('tr[data-p]').forEach((tr,i)=>tr.onclick=e=>{
    if(e.target.dataset.ck!==undefined||e.metaKey||e.ctrlKey||e.shiftKey)
      return togglePick(rows[i].p,rows[i].s);
    select(rows[i])});
  paint(d);
}

const AGECOL={'< 1 week':'#3fb950','< 1 month':'#57c463','< 3 months':'#9bc53d',
  '< 6 months':'#d29922','< 1 year':'#e8833a','< 2 years':'#f0883e','2+ years':'#f85149'};

function renderAge(){
  const A=DATA.age,B=A.buckets;
  const tot=Object.values(B).reduce((s,x)=>s+x.bytes,0)||1;
  const d=document.createElement('div');d.className='pane on';
  const order=['< 1 week','< 1 month','< 3 months','< 6 months','< 1 year','< 2 years','2+ years'];
  d.innerHTML=`<div class="hint">Every file 50 MB or larger, placed on a timeline by when it was last modified. Red is old.</div>`
    +`<div class="agebar">`+order.map(k=>{const v=B[k]||{bytes:0,count:0};
      return v.bytes?`<div style="width:${v.bytes/tot*100}%;background:${AGECOL[k]}"
        title="${k}: ${fmt(v.bytes)} across ${v.count} files"></div>`:''}).join('')+`</div>`
    +`<div class="legend">`+order.map(k=>{const v=B[k]||{bytes:0,count:0};
      return `<span><i style="background:${AGECOL[k]}"></i>${k} — ${fmt(v.bytes)} (${v.count})</span>`}).join('')+`</div>`
    +`<h3 style="margin-top:26px">Big &amp; Untouched — 100 MB+, not modified in over a year</h3>`
    +(A.untouched.length?`<table><thead><tr><th>Path</th><th class="num">Age</th><th class="num">Size</th><th></th></tr></thead><tbody>`
      +A.untouched.map(u=>`<tr><td class="p" title="${esc(u.path)}">${esc(u.path)}</td>`
        +`<td class="num" style="color:${u.age_days>730?'var(--bad)':'var(--warn)'}">${(u.age_days/365).toFixed(1)}y</td>`
        +`<td class="num">${fmt(u.size)}</td>`
        +`<td class="num"><button class="stage-one" data-p="${esc(u.path)}" `
        +`style="background:none;border:1px solid var(--line);color:var(--dim);border-radius:4px;`
        +`padding:2px 8px;cursor:pointer;font-size:11px">stage</button></td></tr>`).join('')
      +`</tbody></table>`
      +`<button class="act" id="stage-all-old">Stage all ${A.untouched.length} — ${fmt(A.untouched.reduce((s,u)=>s+u.size,0))}</button>`
      +`<button class="act" id="pick-all-old">Select all ${A.untouched.length} instead</button>`
      :`<div class="empty">Nothing large has gone untouched for a year.</div>`);
  paint(d);
  d.querySelectorAll('.stage-one').forEach(b=>b.onclick=()=>stageIt([b.dataset.p]));
  const sa=d.querySelector('#stage-all-old');
  if(sa)sa.onclick=()=>stageIt(A.untouched.map(u=>u.path),'big & untouched');
  const pa=d.querySelector('#pick-all-old');
  if(pa)pa.onclick=()=>{A.untouched.forEach(u=>PICK.set(u.path,u.size));selbar();draw()};
}

function renderQuick(){
  const d=document.createElement('div');d.className='pane on';
  const Q=DATA.quick||[],tot=Q.reduce((s,q)=>s+q.size,0);
  d.innerHTML=`<div class="hint">Unique reclaimable space within the scanned root, totalled when the scan landed. <b class="pill safe">safe</b> regenerates on its own; <b class="pill review">review</b> holds real data.</div>`
    +`<table><thead><tr><th>Category</th><th>Tier</th><th class="num">Size</th><th></th></tr></thead><tbody>`
    +Q.map((q,i)=>`<tr><td>${esc(q.label)}</td><td><span class="pill ${q.tier}">${q.tier}</span></td>`
      +`<td class="num">${fmt(q.size)}</td>`
      +`<td class="num"><button class="qs" data-i="${i}" style="background:none;border:1px solid var(--line);`
      +`color:var(--dim);border-radius:4px;padding:2px 8px;cursor:pointer;font-size:11px">stage</button></td></tr>`).join('')
    +`</tbody></table><h3 style="margin-top:22px">Total across all categories — ${fmt(tot)}</h3>`
    +`<div class="hint">Build artifacts found by a separate walk: <b>fastmac builds --age 60</b></div>`;
  paint(d);
  d.querySelectorAll('.qs').forEach(b=>b.onclick=()=>stageIt(Q[+b.dataset.i].paths));
}

function renderDupes(){
  const d=document.createElement('div');d.className='pane on';
  const G=DATA.dupes||[];
  if(!G.length){d.innerHTML=`<div class="empty">No duplicates found — or the scan ran without <b>--dupes</b>.</div>`;return paint(d)}
  const waste=G.reduce((s,g)=>s+g.wasted,0);
  d.innerHTML=`<div class="hint">Matched byte for byte: same size, same 64 KB head, same full digest. `
    +`Reclaimable if you keep one copy of each: <b>${fmt(waste)}</b> across ${G.length} groups.</div>`
    +`<button class="act" id="dupe-all" style="margin-bottom:14px">Stage every extra copy — ${fmt(waste)}</button>`
    +G.slice(0,250).map((g,i)=>`<div class="grp"><div><span>${g.count} copies × ${fmt(g.size)}</span>`
      +`<span style="color:var(--warn)">${fmt(g.wasted)} wasted</span></div><ul>`
      +g.paths.map((p,j)=>`<li><span title="${esc(p)}">${esc(p)}</span>`
        +(j===0?`<button disabled style="opacity:.4;cursor:default">keep</button>`
               :`<button class="ds" data-p="${esc(p)}">stage</button>`)+`</li>`).join('')
      +`</ul></div>`).join('');
  paint(d);
  d.querySelectorAll('.ds').forEach(b=>b.onclick=()=>stageIt([b.dataset.p],'duplicate'));
  const da=d.querySelector('#dupe-all');
  if(da)da.onclick=()=>{if(confirm(`Stage ${G.reduce((a,g)=>a+g.count-1,0)} extra copies?\nThe first copy in each group is kept.`))
    stageIt(G.flatMap(g=>g.paths.slice(1)),'duplicate')};
}

function renderApps(){
  const d=document.createElement('div');d.className='pane on';
  const A=DATA.apps||[];
  if(!A.length){d.innerHTML=`<div class="empty">Run with <b>--apps</b> to map application footprints.</div>`;return paint(d)}
  d.innerHTML=`<div class="hint">True footprint: the bundle plus every cache, preference, container, `
    +`HTTP store and log it left in your Library. <b>Uninstall</b> stages the whole set, not just the icon.</div>`
    +`<table><thead><tr><th>Application</th><th class="num">Bundle</th><th class="num">Leftovers</th>`
    +`<th class="num">Total</th><th class="num">Last used</th><th></th></tr></thead><tbody>`
    +A.map((a,i)=>{const lu=a.last_used?`${days(a.last_used)}d ago`:'never';
      const old=!a.last_used||days(a.last_used)>120;
      return `<tr><td>${esc(a.name)}${a.electron?` <span class="pill review" title="Bundles its own copy of Chromium">electron</span>`:''}</td>`
      +`<td class="num" style="color:var(--dim)">${fmt(a.bundle_size)}</td>`
      +`<td class="num" style="color:var(--dim)">${a.leftover_size?fmt(a.leftover_size):'—'}</td>`
      +`<td class="num">${fmt(a.total)}</td>`
      +`<td class="num" style="color:${old?'var(--warn)':'var(--faint)'}">${lu}</td>`
      +`<td class="num"><button class="un" data-i="${i}" style="background:none;border:1px solid var(--line);`
      +`color:var(--dim);border-radius:4px;padding:2px 8px;cursor:pointer;font-size:11px">uninstall</button></td></tr>`}).join('')
    +`</tbody></table>`
    +(DATA.orphans&&DATA.orphans.length?`<h3 style="margin-top:26px">Orphaned data — the app is gone, its data stayed</h3>`
      +`<table><thead><tr><th>Folder</th><th class="num">Size</th><th></th></tr></thead><tbody>`
      +DATA.orphans.map(o=>`<tr><td class="p" title="${esc(o.path)}">${esc(o.path)}</td>`
        +`<td class="num">${fmt(o.size)}</td><td class="num"><button class="os" data-p="${esc(o.path)}" `
        +`style="background:none;border:1px solid var(--line);color:var(--dim);border-radius:4px;`
        +`padding:2px 8px;cursor:pointer;font-size:11px">stage</button></td></tr>`).join('')
      +`</tbody></table>`:'');
  paint(d);
  d.querySelectorAll('.un').forEach(b=>b.onclick=()=>{const a=A[+b.dataset.i];
    if(confirm(`Uninstall ${a.name} completely?\n\nThis stages the bundle plus ${a.leftovers.length} `
      +`Library items — ${fmt(a.total)} total. Nothing is removed until you purge.`))
      stageIt([a.path,...a.leftovers.map(l=>l.path)],'uninstall '+a.name)});
  d.querySelectorAll('.os').forEach(b=>b.onclick=()=>stageIt([b.dataset.p]));
}

/* ───────────────────────── staging queue ───────────────────── */
/* In live mode the queue lives in the server process, so it is the same queue the
   CLI sees. Opened as a plain file, we fall back to localStorage + a copyable command. */
let QUEUE=[];
if(!LIVE){try{QUEUE=JSON.parse(localStorage.getItem('fastmac.queue')||'[]').map(p=>({path:p,size:0}))}catch(e){}}
function qcount(){document.getElementById('qcount').textContent=QUEUE.length}

async function refreshQueue(){
  if(!LIVE)return qcount();
  try{const st=await api('/api/state');QUEUE=st.queue;qcount();side()}catch(e){}
}

async function stageIt(paths,reason){
  paths=paths.filter(Boolean);
  if(!paths.length)return;
  if(LIVE){
    try{
      const r=await api('/api/stage',{paths,reason:reason||'staged from the UI'});
      QUEUE=r.queue;qcount();
      const ref=(r.refused||[]);
      toast(`${r.added} staged`+(ref.length?` · ${ref.length} refused`:'')
        +(ref.length?`\n${ref.slice(0,4).map(x=>'· '+base(x.path)+' — '+x.why).join('\n')}`:''));
      PICK.clear();selbar();side();
    }catch(e){toast('Could not stage: '+e.message)}
  }else{
    let n=0;for(const p of paths)if(!QUEUE.some(q=>q.path===p)){QUEUE.push({path:p,size:0});n++}
    localStorage.setItem('fastmac.queue',JSON.stringify(QUEUE.map(q=>q.path)));
    qcount();PICK.clear();selbar();side();
    toast(`${n} staged locally. This page is read-only — run\n  fastmac serve\nto delete from here.`);
  }
}

function pathUnder(path,root){return path===root||path.startsWith((root.endsWith('/')?root:root+'/'))}
function subtractNode(n,d){
  n.s=Math.max(0,(n.s||0)-d.s); n.l=Math.max(0,(n.l||0)-d.l);
  n.f=Math.max(0,(n.f||0)-d.f); n.d=Math.max(0,(n.d||0)-d.d);
}
function removeFromTree(n,item){
  if(!n||!pathUnder(item.path,n.p))return null;
  if(item.path===n.p){
    const d={s:n.s||0,l:n.l||n.s||0,f:n.f||0,d:n.d||0};
    n.s=0;n.l=0;n.f=0;n.d=0;n.c=[];return d;
  }
  const kids=n.c||[];
  for(let i=0;i<kids.length;i++){
    const k=kids[i];if(k.other)continue;
    if(k.p===item.path){
      kids.splice(i,1);
      const d={s:k.s||0,l:k.l||k.s||0,f:k.f||0,d:(k.d||0)+1};
      subtractNode(n,d);return d;
    }
    if(pathUnder(item.path,k.p)){
      const d=removeFromTree(k,item);if(d)subtractNode(n,d);return d;
    }
  }
  /* The item was folded into this node's "smaller items" bucket. */
  const d={s:Number(item.size)||0,l:Number(item.logical??item.size)||0,
           f:item.is_dir?0:1,d:0};
  const other=kids.find(k=>k.other);
  if(other){other.s=Math.max(0,(other.s||0)-d.s);other.l=Math.max(0,(other.l||0)-d.l)}
  subtractNode(n,d);return d;
}
function applyRemoved(items){
  if(!items||!items.length)return;
  const seen=[];
  for(const item of items){
    if(!item||typeof item.path!=='string'||seen.some(p=>pathUnder(item.path,p)))continue;
    seen.push(item.path);removeFromTree(DATA.tree,item);
  }
  DATA.totals.bytes=DATA.tree.s;DATA.totals.files=DATA.tree.f;DATA.totals.dirs=DATA.tree.d;
  const mb=document.getElementById('mapped-bytes'),mf=document.getElementById('mapped-files'),md=document.getElementById('mapped-dirs');
  if(mb)mb.textContent=fmt(DATA.tree.s);if(mf)mf.textContent=DATA.tree.f.toLocaleString();if(md)md.textContent=DATA.tree.d.toLocaleString();
  if(DATA.age?.untouched)DATA.age.untouched=DATA.age.untouched.filter(u=>!items.some(i=>pathUnder(u.path,i.path)));
  if(DATA.quick)DATA.quick=DATA.quick.map(q=>{
    let size=q.size;
    for(const i of items)for(const p of (q.paths||[])){
      if(pathUnder(p,i.path))return null;
      if(pathUnder(i.path,p))size-=Number(i.size)||0;
    }
    return size>=10*1024*1024?{...q,size}:null;
  }).filter(Boolean);
  if(DATA.dupes)DATA.dupes=DATA.dupes.filter(g=>!g.paths.some(p=>items.some(i=>pathUnder(p,i.path))));
  if(DATA.apps)DATA.apps=DATA.apps.filter(a=>!items.some(i=>pathUnder(a.path,i.path)));
  if(DATA.orphans)DATA.orphans=DATA.orphans.filter(o=>!items.some(i=>pathUnder(o.path,i.path)));
  ROOT=DATA.tree;CUR=DATA.tree;stack.length=0;SEL=null;PICK.clear();selbar();draw();
}

async function unstage(path){
  if(LIVE){try{const r=await api('/api/unstage',{paths:[path]});QUEUE=r.queue}catch(e){}}
  else{QUEUE=QUEUE.filter(q=>q.path!==path);
       localStorage.setItem('fastmac.queue',JSON.stringify(QUEUE.map(q=>q.path)))}
  qcount();side();
}

async function purge(){
  if(!LIVE)return toast('This page is read-only. Run  fastmac serve  to delete from here.');
  if(!QUEUE.length)return;
  const tot=QUEUE.reduce((a,b)=>a+(b.size||0),0);
  const what=`move ${QUEUE.length} items (${fmt(tot)}) to the Trash`;
  if(!confirm(`About to ${what}.\n\n`+QUEUE.slice(0,12).map(q=>'· '+q.path).join('\n')
    +(QUEUE.length>12?`\n… and ${QUEUE.length-12} more`:'')
    +'\n\nRecoverable from the Trash.'))return;
  try{
    const r=await api('/api/purge',{apply:true});
    QUEUE=r.queue;qcount();side();
    applyRemoved(r.removed||[]);
    let m=`${fmt(r.moved||0)} moved to Trash across ${r.items} items`;
    if(r.blocked&&r.blocked.length)m+=`\n${r.blocked.length} blocked by the safety guard`;
    if(r.failed&&r.failed.length)m+=`\n${r.failed.length} failed`;
    toast(m);
  }catch(e){toast('Purge failed: '+e.message)}
}

function toast(msg){
  const d=document.createElement('div');
  d.style.cssText='position:fixed;left:50%;transform:translateX(-50%);top:64px;background:var(--panel2);'
    +'border:1px solid var(--line);border-radius:9px;padding:11px 16px;z-index:80;font-size:12.5px;'
    +'white-space:pre-line;box-shadow:0 8px 28px rgba(0,0,0,.55);max-width:560px;line-height:1.5';
  d.textContent=msg;document.body.appendChild(d);
  setTimeout(()=>d.remove(),5200);
}

/* ───────────────────────── navigation ──────────────────────── */
function drill(n){if(!n.c)return;stack.push(CUR);CUR=n;draw()}
function up(){if(stack.length){CUR=stack.pop();draw()}}
function goto(i){while(stack.length>i){CUR=stack.pop()}draw()}
function empty(msg){const d=document.createElement('div');d.className='empty';d.textContent=msg;paint(d)}
function paint(el){stage.innerHTML='';const w=document.createElement('div');
  w.style.padding='16px';w.appendChild(el);stage.appendChild(w)}

let SEL=null;
function select(n){SEL=n;side()}

function side(){
  const s=document.getElementById('side');
  const n=SEL||CUR;
  const comp=n.l&&n.l>n.s?((n.l-n.s)/n.l*100):0;
  s.innerHTML=`<h3>Inspector</h3><div class="path">${esc(n.p||'')}</div>`
    +`<div class="kv"><span>Size on disk</span><span>${fmt(n.s)}</span></div>`
    +(n.l?`<div class="kv"><span>Logical size</span><span>${fmt(n.l)}</span></div>`:'')
    +(comp>0.5?`<div class="kv" title="Logical size minus blocks actually allocated. Sparse files (disk images, VM volumes) dominate this on a dev machine; APFS compression is the rest."><span>Sparse + compressed</span><span style="color:var(--good)">${fmt(n.l-n.s)} (${comp.toFixed(0)}%)</span></div>`:'')
    +(n.f!==undefined?`<div class="kv"><span>Files</span><span>${n.f.toLocaleString()}</span></div>`:'')
    +(n.d!==undefined?`<div class="kv"><span>Folders</span><span>${n.d.toLocaleString()}</span></div>`:'')
    +(n.m?`<div class="kv"><span>Modified</span><span>${new Date(n.m*1000).toLocaleDateString()}</span></div>`:'')
    +(()=>{const par=(n===CUR)?(stack.length?stack[stack.length-1]:null):CUR;
       return par&&par.s?`<div class="kv"><span>Share of ${esc(par.n).slice(0,14)}</span><span>${(n.s/par.s*100).toFixed(1)}%</span></div>`:''})()
    +(n.c?`<h3>Largest inside</h3>`+n.c.slice(0,12).map(k=>
      `<div class="kv"><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:175px">${esc(k.n)}</span><span>${fmt(k.s)}</span></div>`).join(''):'')
    +`<h3>Actions</h3>`
    +`<button class="act" id="copy-path">Copy path</button>`
    +(LIVE&&n.p?`<button class="act" id="reveal">Reveal in Finder</button>`:'')
    +(n.p&&!n.other?`<button class="act" id="picktoggle">${picked(n.p)?'Deselect':'Select'}</button>`
      +`<button class="act danger" id="stage-sel">Add to cleanup queue</button>`:'')
    +`<h3>Cleanup queue</h3>`
    +(QUEUE.length?QUEUE.map((q,i)=>`<div class="kv"><span style="overflow:hidden;text-overflow:ellipsis;`
      +`white-space:nowrap;max-width:200px;font-family:Menlo,monospace;font-size:10.5px" title="${esc(q.path)}">${esc(base(q.path))}</span>`
      +`<span>${q.size?fmt(q.size)+' ':''}<button data-qp="${esc(q.path)}" class="qrm" style="background:none;border:none;color:var(--faint);`
      +`cursor:pointer;font-size:14px;line-height:1">×</button></span></div>`).join('')
      +`<div class="kv" style="border:none;padding-top:8px"><span><b>${QUEUE.length} items</b></span>`
      +`<span><b>${fmt(QUEUE.reduce((a,b)=>a+(b.size||0),0))}</b></span></div>`
      +(LIVE
        ?`<button class="act" id="qtrash">Move to Trash</button>`
         +`<button class="act" id="qclear">Clear queue</button>`
        :`<button class="act" id="qcopy">Copy purge command</button>`
         +`<button class="act" id="qclear">Clear queue</button>`
         +`<div class="hint" style="margin-top:9px">Read-only page. Run <b>fastmac serve</b> to delete from here.</div>`)
      :`<div class="hint">Empty. Select items in any view, then add them here.</div>`);
  const b=document.getElementById('stage-sel');
  if(b)b.onclick=()=>stageIt([n.p]);
  const cp=s.querySelector('#copy-path');
  if(cp)cp.onclick=()=>navigator.clipboard.writeText(n.p||'').then(()=>{cp.textContent='Copied'}).catch(()=>toast('Could not copy path'));
  const pt=document.getElementById('picktoggle');
  if(pt)pt.onclick=()=>togglePick(n.p,n.s);
  s.querySelectorAll('.qrm').forEach(x=>x.onclick=()=>unstage(x.dataset.qp));
  const qc=s.querySelector('#qcopy');
  if(qc)qc.onclick=()=>{navigator.clipboard.writeText(
    'fastmac stage '+QUEUE.map(q=>shellQuote(q.path)).join(' ')+' && fastmac queue');
    qc.textContent='Copied — paste in your terminal'};
  const qt=s.querySelector('#qtrash');if(qt)qt.onclick=purge;
  const cl=s.querySelector('#qclear');
  if(cl)cl.onclick=async()=>{if(confirm('Clear the queue? Nothing is deleted.')){
    if(LIVE){try{const r=await api('/api/unstage',{all:true});QUEUE=r.queue}catch(e){}}
    else{QUEUE=[];localStorage.setItem('fastmac.queue','[]')}
    qcount();side()}};
  const rv=s.querySelector('#reveal');
  if(rv)rv.onclick=()=>api('/api/reveal',{path:n.p}).catch(e=>toast(e.message));
}

function crumbs(){
  const c=document.getElementById('crumbs');
  const parts=[...stack,CUR];
  c.innerHTML=parts.map((n,i)=>i===parts.length-1
    ? `<b>${esc(n.n)}</b> <span>${fmt(n.s)}</span>`
    : `<a data-i="${i}">${esc(n.n)}</a><span>›</span>`).join(' ');
  c.querySelectorAll('a').forEach(a=>a.onclick=()=>goto(+a.dataset.i));
}


/* ─────────────────────── live memory monitor ────────────────────── */
const HIST=[];const HMAX=150;      /* ~5 min at 2s */
let memTimer=null,memEpoch=0,memAbort=null;

function memColors(){return{app:'#4c9aff',wired:'#a371f7',comp:'#d29922',free:'#2d3643'}}

function renderMem(){
  const epoch=++memEpoch;
  if(memAbort)memAbort.abort();
  const d=document.createElement('div');d.className='pane on';
  d.innerHTML=`<div id="memroot"><div class="empty">reading memory…</div></div>`;
  paint(d);
  pollMem(epoch);
  clearInterval(memTimer);
  memTimer=setInterval(()=>{if(VIEW==='mem')pollMem(epoch);else {clearInterval(memTimer);memTimer=null}},2000);
}

async function pollMem(epoch=memEpoch){
  const root=document.getElementById('memroot');
  if(!root||epoch!==memEpoch||VIEW!=='mem')return;
  if(!LIVE){
    root.innerHTML=`<div class="empty">The RAM monitor needs the local server.<br><br>`
      +`<code style="color:var(--accent)">fastmac serve</code><br><br>`
      +`<span style="font-size:12px">A saved report is a static file — it cannot read live memory. RAM sampling is independent of the disk scan.</span></div>`;
    return;
  }
  let r;const controller=new AbortController();memAbort=controller;
  try{r=await api('/api/mem',undefined,controller.signal)}catch(e){
    if(e.name==='AbortError')return;
    root.innerHTML=`<div class="empty">Lost the connection to fastmac serve.</div>`;return}
  finally{if(memAbort===controller)memAbort=null}
  if(epoch!==memEpoch||VIEW!=='mem')return;
  const m=r.mem,P=r.procs,dk=r.disk,C=memColors();
  HIST.push(m);if(HIST.length>HMAX)HIST.shift();

  const pc=x=>(m.total?x/m.total*100:0);
  const seg=(w,c,label)=>w>0.8?`<div style="width:${w}%;background:${c}" title="${label}"></div>`:'';

  root.innerHTML=`
  <div class="verdict ${m.level}">${esc(m.verdict)}</div>
  <div class="mgrid">
    <div class="card"><div class="lab">In use</div><div class="big">${fmt(m.used)}</div>
      <div class="sub">of ${fmt(m.total)} installed</div>
      <div class="pbar"><div style="width:${pc(m.used)}%;background:${
        m.level==='bad'?'var(--bad)':m.level==='warn'?'var(--warn)':'var(--good)'}"></div></div></div>
    <div class="card"><div class="lab">Memory pressure</div>
      <div class="big" style="color:${m.level==='bad'?'var(--bad)':m.level==='warn'?'var(--warn)':'var(--good)'}">${m.pressure.toFixed(0)}%</div>
      <div class="sub">${fmt(m.free)} free · ${fmt(m.filebacked+m.purgeable)} reclaimable</div></div>
    <div class="card"><div class="lab">Compressor</div><div class="big">${m.ratio.toFixed(1)}×</div>
      <div class="sub">${fmt(m.stored)} squeezed into ${fmt(m.compressor)}</div></div>
    <div class="card"><div class="lab">Swap on disk</div>
      <div class="big" style="color:${m.swap_used>1073741824?'var(--bad)':m.swap_used>268435456?'var(--warn)':'var(--ink)'}">${fmt(m.swap_used)}</div>
      <div class="sub">of ${fmt(m.swap_total)} allocated</div>
      <div class="pbar"><div style="width:${m.swap_total?m.swap_used/m.swap_total*100:0}%;background:${
        m.swap_used>1073741824?'var(--bad)':'var(--warn)'}"></div></div></div>
  </div>

  <h3>Breakdown</h3>
  <div class="stack">
    ${seg(pc(m.app),C.app,'App memory')}
    ${seg(pc(m.wired),C.wired,'Wired')}
    ${seg(pc(m.compressor),C.comp,'Compressed')}
    ${seg(pc(m.free),C.free,'Free')}
  </div>
  <div class="legend">
    <span><i style="background:${C.app}"></i>App ${fmt(m.app)}</span>
    <span><i style="background:${C.wired}"></i>Wired ${fmt(m.wired)}</span>
    <span><i style="background:${C.comp}"></i>Compressed ${fmt(m.compressor)}</span>
    <span><i style="background:${C.free}"></i>Free ${fmt(m.free)}</span>
  </div>

  <h3 style="margin-top:24px">Last ${(HIST.length>1?((HIST[HIST.length-1].t-HIST[0].t)/60):0).toFixed(1)} minutes</h3>
  <div id="memchart"></div>

  <h3 style="margin-top:24px">Top consumers, grouped by app</h3>
  <table><thead><tr><th>Application</th><th class="num">Processes</th>
    <th class="num">Resident</th><th class="num">Share</th></tr></thead><tbody>
  ${P.map(p=>`<tr><td>${esc(p.name)}</td>
    <td class="num" style="color:${p.procs>20?'var(--warn)':'var(--dim)'}">${p.procs}</td>
    <td class="num">${fmt(p.rss)}</td>
    <td class="num" style="color:var(--dim)">${p.share.toFixed(1)}%</td></tr>`).join('')}
  </tbody></table>
  <div class="hint" style="margin-top:12px">Resident size double-counts framework pages shared
  between an app's helper processes, so these sum to more than real usage. Process count is the
  honest signal for Chromium-based apps.</div>

  <h3 style="margin-top:24px">Disk</h3>
  <div class="kv"><span>Free on ${esc(dk.path)}</span><span>${fmt(dk.free)} of ${fmt(dk.total)}</span></div>
  <div class="pbar"><div style="width:${dk.pct}%;background:${
    dk.pct>90?'var(--bad)':dk.pct>80?'var(--warn)':'var(--good)'}"></div></div>`;

  drawMemChart();
}

function drawMemChart(){
  const host=document.getElementById('memchart');
  if(!host||HIST.length<2)return;
  const W=host.clientWidth||820,H=118,C=memColors();
  const tot=HIST[HIST.length-1].total||1;
  const svg=svgEl(W,H);
  svg.appendChild(mk('rect',{x:0,y:0,width:W,height:H,fill:'var(--panel)',rx:7}));
  /* fill the width while the history is still short, then slide once it's full */
  const span=Math.max(HIST.length-1,1);
  const X=i=>i/span*W, Y=v=>H-(v/tot)*H;
  const bands=[['app',C.app],['wired',C.wired],['compressor',C.comp]];
  let floor=new Array(HIST.length).fill(0);
  for(const[key,color]of bands){
    let up=`M${X(0)} ${Y(floor[0])}`,down='';
    HIST.forEach((h,i)=>{const v=floor[i]+h[key];up+=`L${X(i)} ${Y(v)}`});
    for(let i=HIST.length-1;i>=0;i--)down+=`L${X(i)} ${Y(floor[i])}`;
    svg.appendChild(mk('path',{d:up+down+'Z',fill:color,'fill-opacity':.72}));
    HIST.forEach((h,i)=>floor[i]+=h[key]);
  }
  /* swap as a dashed overlay line */
  const sMax=Math.max(...HIST.map(h=>h.swap_total))||1;
  let sw='';HIST.forEach((h,i)=>{sw+=(i?'L':'M')+X(i)+' '+(H-(h.swap_used/sMax)*H*0.92)});
  svg.appendChild(mk('path',{d:sw,fill:'none',stroke:'var(--bad)','stroke-width':1.5,
    'stroke-dasharray':'3 3','stroke-opacity':.85}));
  const lg=mk('text',{x:W-8,y:14,'text-anchor':'end',class:'lbl',fill:'var(--bad)','font-size':10});
  lg.textContent='swap';svg.appendChild(lg);
  host.innerHTML='';host.appendChild(svg);
}

const VIEWS={folders:renderFolders,treemap:renderTreemap,sunburst:renderSunburst,
  flame:renderFlame,bubbles:renderBubbles,mindmap:renderMindmap,top:renderTop,
  age:renderAge,quick:renderQuick,dupes:renderDupes,apps:renderApps,mem:renderMem};
const TREEVIEWS=new Set(['folders','treemap','sunburst','flame','bubbles','mindmap','top']);

function draw(){crumbs();(VIEWS[VIEW]||renderFolders)();side()}

document.querySelectorAll('nav button').forEach(b=>b.onclick=()=>{
  document.querySelectorAll('nav button').forEach(x=>x.classList.remove('on'));
  b.classList.add('on');
  const previous=VIEW;VIEW=b.dataset.v;
  if(previous==='mem'&&VIEW!=='mem'){
    memEpoch++;if(memAbort)memAbort.abort();clearInterval(memTimer);memTimer=null;
  }
  document.getElementById('crumbs').style.display=TREEVIEWS.has(VIEW)?'flex':'none';
  draw();
});
addEventListener('resize',()=>{if(TREEVIEWS.has(VIEW))draw()});
addEventListener('keydown',e=>{
  if(e.key==='Escape'||e.key==='Backspace'){e.preventDefault();up()}
  const i=parseInt(e.key);
  if(i>=1&&i<=9){const b=document.querySelectorAll('nav button')[i-1];if(b)b.click()}
  if(e.key==='Escape')clearPick();
});

/* selection bar wiring */
document.getElementById('selstage').onclick=()=>stageIt([...PICK.keys()]);
document.getElementById('selclear').onclick=clearPick;
qcount();draw();
if(LIVE){api('/api/ping').then(refreshQueue).catch(()=>{
  document.getElementById('livebadge').className='live off';
  document.getElementById('livebadge').innerHTML='<i></i>read-only';
  toast('This token is no longer valid — the server was restarted.\nReopen the URL that fastmac serve printed.');
});}
"""


def build(scan: dict, extras: dict, live: bool = False) -> str:
    data = {
        "root": scan["root"],
        "created": scan["created"],
        "totals": scan["totals"],
        "tree": scan["tree"],
        "age": extras.get("age", {"buckets": {}, "untouched": []}),
        "quick": extras.get("quick", []),
        "dupes": extras.get("dupes", []),
        "apps": extras.get("apps", []),
        "orphans": extras.get("orphans", []),
    }
    t = scan["totals"]
    when = time.strftime("%b %d, %Y at %H:%M", time.localtime(scan["created"]))
    root = str(scan["root"])
    safe_root = html.escape(root, quote=True)
    # A scan path is user-controlled data. Escaping the JSON control characters
    # prevents a filename containing </script> from ending the data script.
    safe_json = (json.dumps(data, separators=(',', ':'))
                 .replace('&', '\\u0026')
                 .replace('<', '\\u003c')
                 .replace('>', '\\u003e'))
    tabs = [("folders", "Folders"), ("sunburst", "Sunburst"), ("flame", "Flame"),
            ("bubbles", "Bubbles"), ("mindmap", "Mind Map"), ("top", "Top Sizes"),
            ("age", "Age Map"), ("treemap", "Treemap"),
            ("quick", "Quick Wins"), ("dupes", "Duplicates"), ("apps", "Apps"),
            ("mem", "Memory")]
    nav = "".join(
        f'<button data-v="{k}"{" class=\"on\"" if k == "folders" else ""}>{lbl}</button>'
        for k, lbl in tabs)

    def gb(n):
        return f"{n / 1024 ** 3:.1f} GB"

    return f"""<!doctype html><html><head><meta charset="utf-8">
<title>fastmac — {safe_root}</title><style>{CSS}</style></head><body>
<header>
  <h1>fastmac</h1>
  <span class="root">{safe_root}</span>
  <div class="stats">
    <span><b id="mapped-bytes">{gb(t['bytes'])}</b> mapped</span>
    <span><b id="mapped-files">{t['files']:,}</b> files</span>
    <span><b id="mapped-dirs">{t['dirs']:,}</b> folders</span>
    <span>{scan.get('elapsed', 0):.1f}s · {when}</span>
    <span>queue<span id="qcount">0</span></span>
    <span class="live{'' if live else ' off'}" id="livebadge"><i></i>{'live' if live else 'read-only'}</span>
  </div>
</header>
<nav>{nav}</nav>
<div id="crumbs"></div>
<main><div id="stage"></div><aside id="side"></aside></main>
<div class="tip" id="tip"></div>
<div id="selbar"><b id="selinfo"></b>
  <button id="selstage">Add to cleanup queue</button>
  <button class="ghost" id="selclear">Clear</button></div>
<script>const DATA={safe_json};const LIVE_MODE={'true' if live else 'false'};</script>
<script>{JS}</script>
</body></html>"""
