const C="indkob-v49";
const SHELL=["./","index.html","supabase.js?v=2.45.4","config.js?v=49","manifest.webmanifest","icon.svg","icon-192.png"];
self.addEventListener("install",e=>e.waitUntil(caches.open(C).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting())));
self.addEventListener("activate",e=>e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim())));
// Kun appens egne filer (samme oprindelse) caches – aldrig data fra databasen.
self.addEventListener("fetch",e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=="GET"||u.origin!==location.origin)return;
  e.respondWith(fetch(e.request,{cache:"no-store"}).then(r=>{if(r.ok){const cp=r.clone();caches.open(C).then(c=>c.put(e.request,cp))}return r})
    .catch(()=>caches.match(e.request).then(m=>m||caches.match(e.request,{ignoreSearch:true}))));
});
// Notifikationer: vis beskeden og sæt et tal på app-ikonet; tryk åbner listen
self.addEventListener("push",e=>{
  let d={}; try{d=e.data?e.data.json():{}}catch(x){d={title:"Indkøb",body:e.data?e.data.text():""}}
  e.waitUntil(Promise.all([
    self.registration.showNotification(d.title||"Indkøb",{body:d.body||"",icon:"icon-192.png",badge:"icon-192.png",tag:"indkob-"+Date.now(),data:{url:"./"}}),
    self.navigator&&self.navigator.setAppBadge?self.navigator.setAppBadge(d.n||1).catch(()=>{}):null]));
});
self.addEventListener("notificationclick",e=>{
  e.notification.close();
  e.waitUntil(self.clients.matchAll({type:"window",includeUncontrolled:true}).then(cs=>{
    const c=cs.find(x=>x.url.startsWith(self.registration.scope)); return c?c.focus():self.clients.openWindow("./")}));
});
