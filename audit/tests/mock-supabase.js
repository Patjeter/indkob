window.__db={kvit:[],lidl_alt:[],lidl_soeg:[],push_subs:[],items:[],bought:[],offers:[],products:[],catalog:JSON.parse(localStorage.getItem('mockcat')||'[]').map(d=>({data:d})),dishes:[],prisalarm:[],prisalarm_hit:[],butik_orden:[]};window.__calls=[];
window.supabase={createClient(){
  const net=()=>window.__offline?{error:{message:'TypeError: Failed to fetch'}}:null;
  const q=(t)=>{let op='select',payload=null,filt=null,mt=null;
    const o={select(){return o},order(){return o},gte(){return o},limit(){return o},single(){return o},
      eq(c,v){filt=[c,[v]];return o},match(m){mt=m;return o},in(c,v){filt=[c,v];return o},
      insert(r){op='insert';payload=r;return o},update(r){op='update';payload=r;return o},delete(){op='delete';return o},upsert(r){op='upsert';payload=r;return o},
      then(res,rej){const e=net(); if(e)return Promise.resolve(e).then(res,rej);
        __calls.push(op+':'+t);
        if(op==='select')return Promise.resolve(__db[t]===undefined?{data:null,error:{message:'relation "'+t+'" does not exist'}}:{data:JSON.parse(JSON.stringify(__db[t])),error:null}).then(res,rej);
        if(op==='insert'&&t==='items'&&window.__noDevCol&&[].concat(payload).some(r=>'added_dev' in r))return Promise.resolve({data:null,error:{message:"Could not find the 'added_dev' column of 'items' in the schema cache"}}).then(res,rej);
        if(window.__rejectOnce===op+':'+t){window.__rejectOnce=null;return Promise.resolve({data:null,error:{message:'permission denied'}}).then(res,rej)}
        if(op==='insert')[].concat(payload).forEach(r=>__db[t].push(JSON.parse(JSON.stringify(r))));
        if(op==='upsert'){const k=t==='push_subs'?'endpoint':t==='butik_orden'?'store':'key';[].concat(payload).forEach(r=>{if(t==='prisalarm'&&!r.id)r.id='al'+Math.random();__db[t]=(__db[t]||[]).filter(x=>x[k]!==r[k]);__db[t].push(JSON.parse(JSON.stringify(r)))})}
        if(op==='update')__db[t].filter(r=>filt[1].includes(r[filt[0]])).forEach(r=>Object.assign(r,payload));
        if(op==='delete'&&t==='push_subs')localStorage.setItem('delsub',String(Date.now()));
        if(op==='delete'&&filt)__db[t]=__db[t].filter(r=>!filt[1].includes(r[filt[0]]));if(op==='delete'&&mt)__db[t]=__db[t].filter(r=>!Object.entries(mt).every(([k,v])=>r[k]===v));
        return Promise.resolve({data:null,error:null}).then(res,rej)}};return o};
  return {rpc(n,a){__calls.push('rpc:'+n);if(n==='prisalarm_scan'){__db.prisalarm.forEach(al=>{if(al.key==='kaffe'&&al.max_price>=35&&!__db.prisalarm_hit.some(h=>h.alarm_id===al.id))__db.prisalarm_hit.push({alarm_id:al.id,store:'Netto',price:28,eq_price:35,valid_to:'2099-10-18'})});return Promise.resolve({data:{nye:1,uden_overvaagning:__db.prisalarm.filter(x=>x.key!=='kaffe').map(x=>x.key)},error:null})}window.__rpc=a;const nye=a.rows.filter(r=>!__db.kvit.some(k=>k.tid===r.tid));nye.forEach(r=>__db.kvit.push({tid:r.tid}));return Promise.resolve({data:{nye:nye.length,kendte:a.rows.length-nye.length,linjer:nye.reduce((s,r)=>s+r.linjer.length,0),varer:12,krydset_af:1,ukendte:['X']},error:null})},auth:{onAuthStateChange(){},async getSession(){return {data:{session:{u:1,user:{email:'b@x'}}}}},async signOut(){}},from:q,channel(){const c={on(){return c},subscribe(){return c}};return c}};
}};
