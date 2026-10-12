const C="indkob-v37";
const SHELL=["./","index.html","supabase.js?v=2.45.4","config.js?v=37","manifest.webmanifest","icon.svg","icon-192.png"];
self.addEventListener("install",e=>e.waitUntil(caches.open(C).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting())));
self.addEventListener("activate",e=>e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim())));
// Kun appens egne filer (samme oprindelse) caches – aldrig data fra databasen.
self.addEventListener("fetch",e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=="GET"||u.origin!==location.origin)return;
  e.respondWith(fetch(e.request,{cache:"no-store"}).then(r=>{if(r.ok){const cp=r.clone();caches.open(C).then(c=>c.put(e.request,cp))}return r})
    .catch(()=>caches.match(e.request).then(m=>m||caches.match(e.request,{ignoreSearch:true}))));
});
