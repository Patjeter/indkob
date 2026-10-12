/* Læser en Lidl-kvittering (tekst fra lidl.dk's htmlPrintedReceipt) om til varelinjer.
   Samme regler som parse_json.py, som historikken blev bygget med:
   - en linje er "navn [stykpris x antal] beløb A|B"
   - "Rabat", "Lidl Plus …" og negative linjer uden momskode lægges på varen lige over
   - SUM afslutter
   Bruges af appens import og af engangsindlæsningen af historikken. */
(function(g){
  const AMT="-?\\d{1,3}(?:\\.\\d{3})*,\\d{2}";
  const ITEM=new RegExp("^\\s*(\\S.*?)\\s+(?:(\\d+,\\d{2}) x\\s+([\\d,]+)\\s+)?("+AMT+")(?: ([AB]))?\\s*$");
  const num=s=>parseFloat(String(s).replace(/\./g,"").replace(",","."));
  const r2=x=>Math.round(x*100)/100;
  function parseLidlText(text){
    const items=[]; let last=null, total=null;
    for(const ln of String(text||"").split(/\r?\n/)){
      if(/^\s*SUM\s/.test(ln)){const p=ln.trim().split(/\s+/); total=num(p[p.length-1]); break}
      const m=ITEM.exec(ln); if(!m)continue;
      const name=m[1].trim(), a=num(m[4]), vat=m[5];
      if((name.startsWith("Rabat")||name.startsWith("Lidl Plus")||(!vat&&a<0))&&last){last.discount=r2(last.discount+a); if(name.startsWith("Lidl Plus"))last.lidlplus=true; continue}
      if(!vat)continue;
      const qty=m[3]?num(m[3]):1, unit=m[2]?num(m[2]):a;
      last={name,qty,unit_price:unit,amount:a,discount:0}; items.push(last);
    }
    return {items,total,parsed_total:r2(items.reduce((s,i)=>s+i.amount+i.discount,0))};
  }
  /* rå kvittering {id,date,store,total,text} → række til kvit_ingest */
  function lidlRow(t,ejer){
    const p=parseLidlText(t.text);
    return {tid:String(t.id),dato:t.date,butik:t.store||null,kaede:"Lidl",total:t.total!=null?+t.total:p.total,parsed_total:p.parsed_total,ejer:ejer||null,kilde:"lidl.dk",
      linjer:p.items.map(i=>[i.name,i.qty,i.unit_price,i.amount,i.discount])};
  }
  g.KVIT={parseLidlText,lidlRow};
})(typeof window!=="undefined"?window:globalThis);
