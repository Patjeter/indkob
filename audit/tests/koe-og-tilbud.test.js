// Kør: python3 -m http.server 8766 (fra repoets rod) og derefter: node audit/tests/koe-og-tilbud.test.js
// Bruger opfundne demodata og en falsk database (mock-supabase.js); intet sendes ud.
const { chromium } = require('playwright'); const fs=require('fs');
const d=n=>new Date(Date.now()+n*864e5).toISOString().slice(0,10);
(async()=>{const b=await chromium.launch({});
const ctx=await b.newContext({viewport:{width:402,height:874},serviceWorkers:'block'});const p=await ctx.newPage();const errs=[];p.on('pageerror',e=>errs.push(e.message));
await p.route('**/config.js*',r=>r.fulfill({body:'window.INDKOB_CONFIG={url:"https://x.supabase.co",anonKey:"k"};',contentType:'text/javascript'}));
await p.route('**/supabase.js*',r=>r.fulfill({body:fs.readFileSync(__dirname+'/mock-supabase.js','utf8'),contentType:'text/javascript'}));
await p.goto((process.env.APP||'http://localhost:8766/'));const CAT=JSON.stringify(JSON.parse(fs.readFileSync(__dirname+'/../demo.json','utf8')).catalog);
await p.evaluate(c=>{localStorage.clear();localStorage.setItem('mockcat',c)},CAT);await p.reload();await p.waitForTimeout(500);
const R=[];const ok=(c,n)=>R.push((c?'OK  ':'FEJL')+' '+n);
await p.evaluate(()=>{__calls.length=0});
await p.fill('#addInput','bananer');await p.press('#addInput','Enter');
await p.evaluate(()=>toggle(items[0]));await p.waitForTimeout(300);
const calls=await p.evaluate(()=>__calls.filter(c=>/items|bought/.test(c)));
ok(calls.indexOf('insert:items')<calls.indexOf('update:items'),'tilføj sendes før afkryds: '+calls.join(','));
await p.evaluate(()=>send({kind:'update',table:'findesikke',id:'x',changes:{a:1}}));await p.waitForTimeout(200);
ok(await p.isVisible('#failedBox')&&/kunne ikke gemmes/.test(await p.textContent('#failedBox')),'afvist ændring vises og gemmes');
ok(await p.evaluate(()=>queue.length===0&&failed.length===1&&JSON.parse(localStorage.getItem('indkob-failed')).length===1),'køen går videre, ændringen er gemt');
await p.evaluate(()=>{__db.findesikke=[{id:'x'}]});await p.click('#failedBox >> text=Prøv igen');await p.waitForTimeout(200);
ok(await p.evaluate(()=>failed.length===0&&__db.findesikke[0].a===1),'Prøv igen sender ændringen');
await p.evaluate(()=>{window.__offline=true; send({kind:'update',table:'items',id:items[0].id,changes:{note:'net'}})});await p.waitForTimeout(300);
ok(await p.evaluate(()=>queue.length===1&&!online),'netfejl: ændringen venter');
await p.evaluate(()=>{window.__offline=false});await p.waitForTimeout(6000);
ok(await p.evaluate(()=>queue.length===0&&__db.items.some(i=>i.note==='net')),'prøver selv igen uden online-hændelse');
// maks og valg af tilbud
await p.evaluate(([dd])=>{offers.push({key:'aeg',store:'Netto',title:'Skrabeæg',price:10,ref_price:null,valid_from:dd[0],valid_to:dd[1],note:'maks 1'}); render()},[[d(-1),d(3)]]);
await p.fill('#addInput','æg');await p.press('#addInput','Enter');await p.waitForTimeout(100);
await p.evaluate(()=>{const i=items.find(x=>x.key==='aeg');patch(i.id,{store:'Netto',qty:'2'})});await p.waitForTimeout(100);
const t=await p.$eval('#stores',e=>e.innerText); const pr=await p.evaluate(()=>BYKEY.aeg.price);
ok(t.includes(`(maks 1 til tilbudspris)`),'maks vises');
ok(new RegExp(`= ${String(10+pr).replace('.',',')}`).test(t.replace(/ /g,' '))||t.includes('= '+(10+pr).toLocaleString('da-DK')+' kr.'),'2. æg til normalpris: '+(t.match(/2 × [^\n]*/)||[''])[0]);
await p.evaluate(()=>{offers.length=0;offers.push({key:'kaffe',store:'Netto',price:30,ref_price:39,valid_from:'2026-01-01',valid_to:'2099-01-01',source:'auto'});render()});
await p.evaluate(()=>{cmpCache.set('aeg',[{store:'føtex',heading:'Æg',price:15,size:'10 stk',offer_unit:1.5,si_unit:'stk',eq_price:12,maks:null,valid_from:new Date().toISOString().slice(0,10),valid_to:new Date(Date.now()+3*864e5).toISOString().slice(0,10)}])});
const id=await p.evaluate(()=>items.find(x=>x.key==='aeg').id); await p.evaluate(i=>{editingItem=i;renderList()},id);await p.waitForTimeout(300);
await p.click('.cmp button[aria-label*="føtex"]');await p.waitForTimeout(200);
ok(await p.evaluate(()=>offers.some(o=>o.store==='føtex'&&o.key==='aeg'&&o.source==='valg')&&__db.offers.some(o=>o.store==='føtex')),'valgt tilbud gemmes');
ok(/15 kr/.test(await p.$eval('#stores',e=>e.innerText)),'listen bruger det valgte tilbuds pris');
R.forEach(x=>console.log(x));console.log('errors',errs);await b.close()})();
