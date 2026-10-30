// No credentials, external requests, deployment or customer files. Run from repository root.
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { performance } from 'node:perf_hooks';
const benchmarkLog = console.log;
console.log = () => {}; // Keep stdout machine-readable; production logs are tested separately.
const workerPath = process.argv[2] || 'Backend/CloudflareGalleryProxy/src/index.js';
const scriptPath = process.argv[3] || 'Backend/GoogleAppsScript/Code.gs';
const worker = (await import(pathToFileURL(path.resolve(workerPath)))).default;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const stats = xs => { const s = xs.toSorted((a,b)=>a-b); return Object.fromEntries([['p50',.5],['p95',.95],['max',1]].map(([k,p])=>[k,s[Math.max(0,Math.ceil(s.length*p)-1)] || 0])); };
const iterator = items => { let index=0; return {hasNext:()=>index<items.length,next:()=>items[index++]}; };
const rows=[];
for (const photos of [1,3,6]) for (const guests of [1,5,20]) {
  const counts={propertyRead:0,propertyWrite:0,folderLookup:0,folderByID:0,folderCreate:0,imageCreate:0,manifestCreate:0,inspection:0,manifestRead:0,imageRead:0,fileSize:0};
  const properties=new Map([['POCKET_PIXELS_ROOT_FOLDER_ID','root'],['POCKET_PIXELS_DEVICE_TOKEN','synthetic-only-placeholder-token'],['MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL','https://benchmark.example.test/']]);
  const folders=[], cacheValues=new Map();
  const driveRoot={getFoldersByName:name=>{counts.folderLookup++;return iterator(folders.filter(f=>f.name===name));},createFolder(name){
    counts.folderCreate++;
    const folder={id:`isolated-${folders.length}`,name,files:[],getId(){return this.id;},getFiles(){counts.inspection++;return iterator(this.files);},createFile(blob,text){
      const manifest=typeof blob==='string';counts[manifest?'manifestCreate':'imageCreate']++;
      const file={getName:()=>manifest?blob:blob.name,getSize:()=>{counts.fileSize++;return manifest?Buffer.byteLength(text):blob.bytes.length;},getBlob:()=>{counts[manifest?'manifestRead':'imageRead']++;return {getDataAsString:()=>text,getBytes:()=>blob.bytes};}};
      this.files.push(file);return file;
    }}; folders.push(folder);return folder;
  }};
  const context=vm.createContext({console:{log(){},error(){}},Utilities:{base64Decode:s=>Array.from(Buffer.from(s,'base64')),base64Encode:b=>Buffer.from(b).toString('base64'),newBlob:(bytes,mimeType,name)=>({bytes,mimeType,name}),formatDate:()=> 'Oct 30, 2026'},
    PropertiesService:{getScriptProperties:()=>({getProperty:k=>{counts.propertyRead++;return properties.get(k)||null;},setProperty:(k,v)=>{counts.propertyWrite++;properties.set(k,v);},deleteProperty:k=>properties.delete(k)})},
    CacheService:{getScriptCache:()=>({get:k=>cacheValues.get(k)||null,put:(k,v)=>cacheValues.set(k,v),remove:k=>cacheValues.delete(k)})},
    DriveApp:{getFolderById:id=>{counts.folderByID++;if(id==='root')return driveRoot;const f=folders.find(f=>f.id===id);if(!f)throw Error('missing');return f;}},
    LockService:{getScriptLock:()=>({tryLock:()=>true,releaseLock(){}})},
    ContentService:{MimeType:{JSON:'json',TEXT:'text'},createTextOutput:text=>({text,setMimeType(){return this;}})},
    HtmlService:{XFrameOptionsMode:{ALLOWALL:1},createHtmlOutput:html=>({getContent:()=>html,setTitle(){return this;},setXFrameOptionsMode(){return this;}})}
  });
  vm.runInContext(fs.readFileSync(scriptPath,'utf8'),context);
  const post=[],readiness=[],cold=[],warm=[];let transferBytes=0,htmlBytes=0;
  const started=performance.now();
  const originalFetch=globalThis.fetch,originalCaches=globalThis.caches;
  const entries=new Map();let pending=[];
  globalThis.caches={default:{async match(r){return entries.get(r.url)?.clone();},async put(r,response){await sleep(25);entries.set(r.url,response.clone());}}};
  const env={APPS_SCRIPT_GALLERY_ORIGIN:'https://script.google.com/macros/s/ISOLATED/exec'};
  try {
    for(let i=0;i<guests;i++) {
      const payload=context.makeSelfTestPayload_(photos);payload.schemaVersion=4;delete payload.gif;delete payload.thermalReceipt;
      payload.galleryToken=(i+1).toString(16).padStart(64,'0');payload.deviceToken='synthetic-only-placeholder-token';payload.receiptVariants={originalFooterStyle:'decorativeBarcodeOnly',defaultStyle:'shareFriendly'};
      for(const image of [...payload.photos,payload.colorReceipt]) {const b=Buffer.alloc(image===payload.colorReceipt?180000:300000,0x5a);b[0]=255;b[1]=216;b[2]=255;image.base64Data=b.toString('base64');}
      const wire=JSON.stringify(payload);transferBytes+=Buffer.byteLength(wire);
      let begin=performance.now();const result=JSON.parse(context.doPost({postData:{contents:wire}}).text);post.push(performance.now()-begin);if(!result.ok)throw Error('synthetic POST rejected');
      begin=performance.now();const status=JSON.parse(context.doGet({parameter:{g:payload.galleryToken,galleryStatus:'1'}}).text);readiness.push(performance.now()-begin);if(status.status!=='complete')throw Error('readiness rejected');
      globalThis.fetch=async raw=>{await sleep(15);const url=new URL(raw);return new Response(context.doGet({parameter:{g:url.searchParams.get('g'),proxy:'raw'}}).text);};
      const request=new Request(`https://benchmark.example.test/?g=${payload.galleryToken}`);
      begin=performance.now();const response=await worker.fetch(request,env,{waitUntil:p=>pending.push(p)});const html=await response.text();cold.push(performance.now()-begin);htmlBytes+=Buffer.byteLength(html);
      if(!html.includes('data-pocket-pixels-gallery-status="complete"'))throw Error('incomplete HTML');
      await Promise.all(pending);pending=[];
      begin=performance.now();const hit=await worker.fetch(request,env,{waitUntil:p=>pending.push(p)});await hit.text();warm.push(performance.now()-begin);if(hit.headers.get('X-Pocket-Pixels-Cache')!=='HIT')throw Error('cache missed');
    }
  } finally {await Promise.all(pending);globalThis.fetch=originalFetch;globalThis.caches=originalCaches;}
  rows.push({photos,guests,postLocalCPUms:stats(post),readinessLocalCPUms:stats(readiness),coldPageMs:stats(cold),warmPageMs:stats(warm),totalMs:performance.now()-started,transferBytes,htmlBytes,counts});
}
benchmarkLog(JSON.stringify({environment:'Node local VM, no network or Drive; Worker mock origin 15ms / cache put 25ms. Bytes are signature-valid deterministic synthetic buffers, not JPEG fidelity fixtures.',rows},null,2));
