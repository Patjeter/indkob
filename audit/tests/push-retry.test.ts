// Kør: PUSH_TEST=1 deno run -A audit/tests/push-retry.test.ts (falsk database og falsk afsendelse)
import { handle } from "../../supabase/functions/push/index.ts";
const ok=(c:boolean,m:string)=>{console.log((c?"OK  ":"FEJL")+" "+m); if(!c) Deno.exitCode=1};
// lille falsk database
// deno-lint-ignore no-explicit-any
const db:any={cron_secret:[{id:1,secret:"s"}],push_retry:[],push_subs:[{endpoint:"A",p256dh:"x",auth:"y",dev:"dA",lang:"da",email:"w@x"},{endpoint:"B",p256dh:"x",auth:"y",dev:"dB",lang:"da",email:"w@x"}],family:[{email:"b@x",name:"Besnik"},{email:"w@x",name:"V"}]};
let nid=1;
// deno-lint-ignore no-explicit-any
const sb:any={rpc:async(n:string)=>({data:n==="push_claim"?claimed.splice(0):[],error:null}),
  from:(t:string)=>{let rows=()=>db[t]; const f:((r:any)=>boolean)[]=[]; let op="select",val:any=null;
    // deno-lint-ignore no-explicit-any
    const q:any={select(){return q},eq(c:string,v:any){f.push(r=>r[c]===v);return q},in(c:string,v:any[]){f.push(r=>v.includes(r[c]));return q},lte(c:string,v:string){f.push(r=>r[c]<=v);return q},limit(){return q},
      delete(){op="delete";return q},update(v:any){op="update";val=v;return q},insert(v:any){op="insert";val=v;return q},maybeSingle(){op="single";return q},
      then(res:any){const m=rows().filter((r:any)=>f.every(fn=>fn(r)));
        if(op==="delete")db[t]=rows().filter((r:any)=>!m.includes(r));
        if(op==="update")m.forEach((r:any)=>Object.assign(r,val));
        if(op==="insert")db[t].push({id:nid++,tries:1,next_at:new Date(Date.now()+60000).toISOString(),...val});
        if(t==="push_subs"&&op==="select"&&readFail)return Promise.resolve({data:null,error:{message:"timeout"}}).then(res);
        return Promise.resolve({data:op==="single"?m[0]||null:m,error:null}).then(res)}};return q}};
let readFail=false;
let claimed:any[]=[{id:"i1",text:"Mælk",name_da:"Mælk",name_sq:null,checked:false,added_dev:"dB2",added_by:"b@x"}];
const fail=new Set(["B"]); const got:string[]=[];
const deliver=(s:any)=>{if(fail.has(s.endpoint))return Promise.reject({statusCode:503}); got.push(s.endpoint); return Promise.resolve()};
const req=(h:Record<string,string>={"x-cron-secret":"s"})=>new Request("http://x",{method:"POST",headers:h,body:"{}"});
ok((await handle(req({}),sb,deliver)).status===401,"uden hemmelighed: 401");
let r=await (await handle(req(),sb,deliver)).json();
ok(r.sent===1&&r.failed===1&&got.join()==="A","telefon A fik beskeden, B fejlede: "+JSON.stringify(r));
ok(db.push_retry.length===1&&db.push_retry[0].endpoint==="B","kun B står til genforsøg");
db.push_retry[0].next_at=new Date(Date.now()-1000).toISOString(); fail.clear();
r=await (await handle(req(),sb,deliver)).json();
ok(r.retried===1&&got.join()==="A,B"&&db.push_retry.length===0,"genforsøg når B uden at sende til A igen: "+got.join());

// læsefejl ved opslag af abonnementer: genforsøget må ikke slettes
claimed=[{id:"i2",text:"Æg",name_da:"Æg",name_sq:null,checked:false,added_dev:"dB2",added_by:"b@x"}]; fail.add("B");
await handle(req(),sb,deliver); ok(db.push_retry.length===1,"ny fejl til B gemt");
db.push_retry[0].next_at=new Date(Date.now()-1000).toISOString(); readFail=true;
r=await (await handle(req(),sb,deliver)).json();
ok(db.push_retry.length===1,"læsefejl: genforsøget beholdes");
readFail=false; fail.clear(); r=await (await handle(req(),sb,deliver)).json();
ok(r.retried===1&&db.push_retry.length===0,"næste kørsel leverer det");
// "Kan du handle nu?": spørgsmål til alle andre, svar til den der spurgte
db.push_subs.push({endpoint:"S",p256dh:"x",auth:"y",dev:"dS",lang:"sq",email:"v@x"},{endpoint:"E",p256dh:"x",auth:"y",dev:"dE",lang:"da",email:"e@x"}); got.length=0;
const pays:any[]=[]; const deliver2=(s:any,p:any)=>{got.push(s.endpoint); pays.push(p); return Promise.resolve()};
db.handle_req=[{id:"h1",asked_by:"v@x",asked_name:"Valentina",n:12,taken_name:null,answers:[]}];
const hreq=(b:any)=>new Request("http://x",{method:"POST",headers:{"x-cron-secret":"s"},body:JSON.stringify(b)});
let rh=await (await handle(hreq({handle:"h1"}),sb,deliver2)).json();
ok(rh.handle===true&&got.sort().join()==="A,B,E","spørgsmål til alle andre end Valentina: "+got.join());
ok(pays[0].title==="Valentina spørger: kan du handle nu?"&&/12 varer/.test(pays[0].body)&&pays[0].actions.length===2&&/\?svar=h1$/.test(pays[0].url),"tekst og knapper: "+pays[0].title);
got.length=0; pays.length=0; db.handle_req[0].answers=[{email:"w@x",name:"Besnik",svar:"nej"}];
await handle(hreq({handle_svar:"h1",email:"w@x",svar:"nej"}),sb,deliver2);
ok(got.join()==="S"&&pays[0].title==="Besnik nuk mund të blejë tani","nej går kun til Valentina (på albansk): "+pays.map(p=>p.title).join());
got.length=0; pays.length=0; db.handle_req[0].answers.push({email:"e@x",name:"Enis",svar:"ja"});
await handle(hreq({handle_svar:"h1",email:"e@x",svar:"ja"}),sb,deliver2);
ok(got.sort().join()==="A,B,S"&&pays.some(p=>p.title==="Enis i merr blerjet")&&pays.some(p=>p.title==="Enis tager indkøbet"),"ja går til alle andre: "+got.join());
ok(pays.every(p=>p.tag==="handle-h1"),"samme tag erstatter spørgsmålet");
