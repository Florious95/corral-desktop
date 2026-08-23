/** 在两个会话之间快速来回切，每次截图，复现「轮转后错排」。 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { loadPairing, DEVICES_KEY } from '/Volumes/nvme/Projects/tmux桌面端/scripts/garble-sweep.mjs';
const CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
// 🔴 用户 2026-08-23 令：收藏里的会话（全是 claude_code 席位）⛔ 测试中一律不点。
const EXCLUDE = (title) => /^claude_code$/i.test((title || '').trim());
const arg=(n,d)=>{const i=process.argv.indexOf(n);return i>=0?process.argv[i+1]:d};
const ORIGIN=arg('--origin','http://localhost:5219'), OUT=arg('--out','/tmp/toggle');
const A=arg('--a','reviewer-r17'), B=arg('--b','reviewer-r16');
const N=Number(arg('--n','16')), DWELL=Number(arg('--dwell','600'));
const CDP=Number(arg('--cdp','9431'));
class Tab{constructor(u){this.u=u;this.id=0;this.p=new Map()}
 async open(){this.ws=new WebSocket(this.u);await new Promise((r,j)=>{this.ws.once('open',r);this.ws.once('error',j)});
  this.ws.on('message',raw=>{let m;try{m=JSON.parse(raw.toString())}catch{return};if(m.id&&this.p.has(m.id)){const{resolve,reject}=this.p.get(m.id);this.p.delete(m.id);m.error?reject(new Error(m.error.message)):resolve(m.result)}})}
 send(me,pa={}){const id=++this.id;return new Promise((res,rej)=>{this.p.set(id,{resolve:res,reject:rej});this.ws.send(JSON.stringify({id,method:me,params:pa}))})}
 async evaluate(e){const r=await this.send('Runtime.evaluate',{expression:e,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw new Error(r.exceptionDetails.text);return r.result?.value}}
const waitOk=async(u,ms)=>{const t=Date.now();for(;;){try{if((await fetch(u)).ok)return}catch{};if(Date.now()-t>ms)throw new Error('to');await sleep(200)}};
mkdirSync(OUT,{recursive:true});
const pairing=loadPairing();
const c=spawn(CHROME,['--remote-debugging-port='+CDP,'--user-data-dir=/tmp/ctog','--headless=new','--no-first-run','--window-size=1400,860','about:blank'],{stdio:'ignore'});
try{
 await waitOk('http://127.0.0.1:'+CDP+'/json/version',20000);
 const t=await (await fetch('http://127.0.0.1:'+CDP+'/json/new?'+ORIGIN+'/',{method:'PUT'})).json();
 const tab=new Tab(t.webSocketDebuggerUrl); await tab.open();
 await tab.send('Runtime.enable'); await tab.send('Page.enable');
 await tab.send('Emulation.setDeviceMetricsOverride',{width:1400,height:860,deviceScaleFactor:1,mobile:false});
 await sleep(400);
 await tab.evaluate(`(()=>{localStorage.setItem(${JSON.stringify(DEVICES_KEY)},${JSON.stringify(JSON.stringify([{id:pairing.id,name:pairing.name,url:pairing.url,token:pairing.token}]))});location.reload();return 1})()`);
 await sleep(1800);
 for(let i=0;i<80;i++){ if(await tab.evaluate(`document.querySelectorAll('.agents-row').length`))break; await sleep(300);}
 const idx=async(name)=>tab.evaluate(`([...document.querySelectorAll('.agents-row')].findIndex(el=>(el.querySelector('.agents-row-title')?.textContent||'').trim()===${JSON.stringify(name)}))`);
 const ia=await idx(A), ib=await idx(B);
 if(ia<0||ib<0) throw new Error('找不到会话 '+A+'/'+B+' ia='+ia+' ib='+ib);
 if(EXCLUDE(A)||EXCLUDE(B)) throw new Error('⛔ 拒绝：'+A+'/'+B+' 属于用户收藏，测试中不许点');
 console.log('A='+A+'#'+ia+'  B='+B+'#'+ib+'  来回 '+N+' 次，停留 '+DWELL+'ms');
 for(let k=1;k<=N;k++){
   const name = (k%2)? A : B, i = (k%2)? ia : ib;
   await tab.evaluate(`(()=>{const el=document.querySelectorAll('.agents-row')[${i}];el.click();return 1})()`);
   await sleep(DWELL);
   const s=await tab.send('Page.captureScreenshot',{format:'png'});
   const f=`k${String(k).padStart(2,'0')}__${name}.png`;
   writeFileSync(join(OUT,f),Buffer.from(s.data,'base64'));
   console.log(' '+f);
 }
}finally{try{c.kill('SIGTERM')}catch{}}
