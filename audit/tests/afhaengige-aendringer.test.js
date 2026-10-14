// Kør: python3 -m http.server 8766 (fra repoets rod) og derefter: node audit/tests/afhaengige-aendringer.test.js
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
// 1) afvist oprettelse blokerer afkrydsningen af samme vare
await p.evaluate(()=>{window.__rejectOnce='insert:items'});
await p.fill('#addInput','bananer');await p.press('#addInput','Enter');await p.evaluate(()=>toggle(items[0]));await p.waitForTimeout(300);
ok(await p.evaluate(()=>failed.length===3&&__db.items.length===0&&queue.length===0),'oprettelse + afkrydsning venter begge: '+await p.evaluate(()=>failed.map(f=>f.op.kind+':'+f.op.table).join(',')));
await p.click('#failedBox >> text=Prøv igen');await p.waitForTimeout(300);
ok(await p.evaluate(()=>__db.items.length===1&&__db.items[0].checked===true&&failed.length===0),'efter Prøv igen: varen findes og er krydset af');
// 2) valgt tilbud vinder over eksisterende tilbud i samme butik
await p.evaluate(([a,z])=>{offers.push({key:'aeg',store:'Netto',title:'Æg',price:1.5,ref_price:null,valid_from:a,valid_to:z,source:'auto'});render()},[d(-1),d(3)]);
await p.fill('#addInput','æg');await p.press('#addInput','Enter');await p.waitForTimeout(100);
await p.evaluate(()=>{const i=items.find(x=>x.key==='aeg');patch(i.id,{store:'Netto',qty:'1'})});
await p.evaluate(([a,z])=>{cmpCache.set('aeg',[{store:'Netto',heading:'Æg billig',price:0.9,size:'1 stk',offer_unit:0.9,si_unit:'stk',eq_price:0.9,maks:null,valid_from:a,valid_to:z},{store:'Netto',heading:'Æg',price:1.5,size:'1 stk',offer_unit:1.5,si_unit:'stk',eq_price:1.5,maks:null,valid_from:a,valid_to:z}])},[d(-1),d(4)]);
const id=await p.evaluate(()=>items.find(x=>x.key==='aeg').id);await p.evaluate(i=>{editingItem=i;renderList()},id);await p.waitForTimeout(300);
await p.click('.cmp li:has-text("Æg billig") button');await p.waitForTimeout(200);
ok(await p.evaluate(()=>unitPrice('aeg','Netto'))===0.9,'listen bruger 0,90 kr.');
await p.evaluate(i=>{editingItem=i;renderList()},id);await p.waitForTimeout(300);
await p.click('.cmp li:has-text("Netto · 1,50") button').catch(()=>{});await p.waitForTimeout(200);
ok(await p.evaluate(()=>offers.filter(o=>o.key==='aeg'&&o.source==='valg').length===1&&__db.offers.filter(o=>o.key==='aeg'&&o.source==='valg').length===1),'nyt valg erstatter det gamle');
R.forEach(x=>console.log(x));console.log('errors',errs);await b.close()})();
