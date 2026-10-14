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
