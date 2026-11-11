// Real production entry points with a controllable Drive API/DriveApp model.
// No credentials, customer media or external network calls.
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function harness() {
  const folders = new Map(), files = new Map(), properties = new Map([
    ['POCKET_PIXELS_ROOT_FOLDER_ID','root'], ['POCKET_PIXELS_DEVICE_TOKEN','synthetic-only-device-credential'],
    ['MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL','https://synthetic.example.test/'], ['MTK_RESUMABLE_UPLOADS_ENABLED','true']]);
  const logs = [], sessions = [];
  let id = 0;
  const iterator = rows => { let i=0; return {hasNext:()=>i<rows.length,next:()=>rows[i++]}; };
  function file(folder, name, bytes, mime='application/json', fixedId) {
    const entry = {id:fixedId || 'file-'+(++id), name, bytes:Buffer.from(bytes), mime, parent:folder.id,
      getId(){return this.id;},getName(){return this.name;},getSize(){return this.bytes.length;},getMimeType(){return this.mime;},
      getBlob(){return {getDataAsString:()=>this.bytes.toString(), getBytes:()=>Array.from(this.bytes)};},
      setContent(text){this.bytes=Buffer.from(text);return this;}};
    files.set(entry.id,entry);folder.files.push(entry);return entry;
  }
  function folder(name, parent=null, fixedId) {
    const entry={id:fixedId || 'folder-'+(++id),name,parent,files:[],children:[],
      getId(){return this.id;},getName(){return this.name;},
      getFoldersByName(n){return iterator(this.children.filter(x=>x.name===n));},
      createFolder(n){return folder(n,this);},getFiles(){return iterator(this.files);},
      getFilesByName(n){return iterator(this.files.filter(x=>x.name===n));},
      createFile(n,text,mime){return file(this,n,text,mime);}};
    folders.set(entry.id,entry);if(parent)parent.children.push(entry);return entry;
  }
  const root=folder('synthetic root',null,'root');
  const response=(code,data={},headers={})=>({getResponseCode:()=>code,getContentText:()=>JSON.stringify(data),getAllHeaders:()=>headers});
  const context=vm.createContext({console:{log:x=>logs.push(x),error:x=>logs.push(x)},
    Utilities:{DigestAlgorithm:{SHA_256:'sha256'},computeDigest:(algorithm,value)=>Array.from(crypto.createHash(algorithm).update(typeof value==='string'?value:Buffer.from(value)).digest()),
      base64Decode:x=>Array.from(Buffer.from(x,'base64')),base64Encode:x=>Buffer.from(x).toString('base64')},
    ScriptApp:{getOAuthToken:()=> 'broad-server-credential-never-to-client'},
    UrlFetchApp:{fetchAll(requests){return requests.map(request=>{
      assert.equal(request.headers.Authorization,'Bearer broad-server-credential-never-to-client');
      const url=new URL(request.url);
      if(url.pathname.endsWith('/generateIds'))return response(200,{ids:Array.from({length:Number(url.searchParams.get('count'))},()=> 'reserved-'+(++id))});
      if(request.method==='post'){
        const metadata=JSON.parse(request.payload);sessions.push(metadata);
        return response(200,{}, {Location:'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=capability-'+sessions.length});
      }
      const entry=files.get(decodeURIComponent(url.pathname.split('/').pop()));
      return entry ? response(200,{id:entry.id,name:entry.name,size:String(entry.bytes.length),mimeType:entry.mime,parents:[entry.parent],trashed:false,sha256Checksum:crypto.createHash('sha256').update(entry.bytes).digest('hex')}) : response(404);
    });}},
    PropertiesService:{getScriptProperties:()=>({getProperty:k=>properties.get(k)||null,setProperty:(k,v)=>properties.set(k,v),deleteProperty:k=>properties.delete(k)})},
    CacheService:{getScriptCache:()=>({get:()=>null,put(){},remove(){}})},
    LockService:{getScriptLock:()=>({tryLock:()=>true,releaseLock(){}})},
    DriveApp:{getFolderById:id=>folders.get(id),getFileById:id=>files.get(id)},
    ContentService:{MimeType:{JSON:'json'},createTextOutput:text=>({text,setMimeType(){return this;}})}});
  for(const name of ['Code.gs','ResumableUploads.gs'])vm.runInContext(fs.readFileSync(path.join(__dirname,name),'utf8'),context);
  const bytes=Buffer.from([255,216,255,1,2,3,4,5]);
  const asset=name=>({filename:name,mimeType:'image/jpeg',bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')});
  const body={transport:'drive-resumable-v1',action:'initialize',deviceToken:'synthetic-only-device-credential',schemaVersion:4,
    galleryToken:'a'.repeat(64),sessionID:'PP-20261111-120000',createdAt:'2026-11-11T04:00:00Z',
    photos:[asset('photo-01.jpg')],colorReceipt:asset('receipt-color.jpg'),
    receiptVariants:{originalFooterStyle:'decorativeBarcodeOnly',defaultStyle:'shareFriendly'}};
  const post=(patch={})=>JSON.parse(context.doPost({postData:{contents:JSON.stringify({...body,...patch})}}).text);
  const complete=index=>{const metadata=sessions[index];assert.ok(metadata);return file(folders.get(metadata.parents[0]),metadata.name,bytes,metadata.mimeType,metadata.id);};
  return {post,body,root,folders,files,properties,sessions,complete,logs,context};
}

test('authorization and capability gate reject before storage mutation',()=>{
  const h=harness();assert.equal(h.post({deviceToken:'wrong'}).ok,false);assert.equal(h.root.children.length,0);
  h.properties.set('MTK_RESUMABLE_UPLOADS_ENABLED','false');assert.equal(h.post().errorCode,'TRANSPORT_UNAVAILABLE');assert.equal(h.root.children.length,0);
});

test('lost initialization ACK, per-file resume, lost finalize ACK and publication are idempotent',()=>{
  const h=harness(),first=h.post();assert.equal(first.status,'transferring');assert.equal(h.sessions.length,2);
  assert.deepEqual(h.post(),first);assert.equal(h.sessions.length,2,'lost ACK reuses scoped sessions');
  h.complete(0);const partial=h.post();assert.equal(partial.assets[0].stored,true);assert.equal(partial.assets[0].uploadURL,undefined);
  assert.equal(h.post({action:'finalize'}).errorCode,'ASSETS_INCOMPLETE');
  h.complete(1);assert.equal(h.post().status,'remotelyStored');
  const done=h.post({action:'finalize'});assert.equal(done.ok,true);assert.equal(done.fileCount,3);
  assert.equal(h.post({action:'finalize'}).status,'existingComplete');
  const gallery=h.root.children.find(x=>x.name.startsWith('gallery-'));
  assert.equal(gallery.files.filter(x=>x.name==='manifest.json').length,1);
  assert.equal(h.sessions.length,2);assert.equal(h.root.children.filter(x=>x.name.startsWith('gallery-')).length,1);
  assert.doesNotMatch(JSON.stringify(first)+h.logs.join('\n'),/broad-server-credential-never-to-client/);
  const ready=JSON.parse(h.context.doGet({parameter:{g:h.body.galleryToken,galleryStatus:'1'}}).text);
  assert.equal(ready.status,'complete');assert.equal(ready.fileCount,3,'existing public contract remains intact');
});

test('expired session keeps its reserved ID and does not restart other assets',()=>{
  const h=harness();h.post();const original=h.sessions[0].id;
  const retry=h.post({expiredAsset:'photo-01.jpg'});
  assert.equal(h.sessions.length,3);assert.equal(h.sessions[2].id,original);
  assert.equal(retry.assets[1].uploadURL.endsWith('capability-2'),true);
});

test('changed identity, media hash, wrong parent and duplicate files cannot publish',()=>{
  const h=harness();h.post();
  assert.equal(h.post({sessionID:'PP-20261111-130000'}).status,'manualInspectionRequired');
  const changed=structuredClone(h.body.photos);changed[0].sha256='f'.repeat(64);
  assert.equal(h.post({photos:changed}).status,'manualInspectionRequired');
  const first=h.complete(0);h.complete(1);first.bytes=Buffer.from('corrupted');
  assert.equal(h.post({action:'finalize'}).status,'manualInspectionRequired');
  first.bytes=Buffer.from([255,216,255,1,2,3,4,5]);first.parent='wrong-parent';
  assert.equal(h.post({action:'finalize'}).status,'manualInspectionRequired');
  first.parent=h.sessions[0].parents[0];
  const gallery=h.folders.get(first.parent);gallery.files.push(first);
  assert.equal(h.post({action:'finalize'}).status,'manualInspectionRequired');
  assert.equal([...h.files.values()].filter(x=>x.name==='manifest.json').length,0);
});

test('equivalent receipt metadata key order does not create a false identity conflict',()=>{
  const h=harness();h.post();
  const reply=h.post({receiptVariants:{defaultStyle:'shareFriendly',originalFooterStyle:'decorativeBarcodeOnly'}});
  assert.equal(reply.ok,true);assert.equal(h.sessions.length,2);
});

test('legacy mutation cannot race a partially uploaded resumable gallery',()=>{
  const h=harness();h.post();assert.throws(()=>h.context.guardLegacyResumableMutation_(h.body.galleryToken),/unfinished resumable/);
  h.complete(0);h.complete(1);h.post({action:'finalize'});
  assert.doesNotThrow(()=>h.context.guardLegacyResumableMutation_(h.body.galleryToken));
});
