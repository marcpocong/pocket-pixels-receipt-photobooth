// Tests experiment safety/correctness with mocks. Does not claim real Drive API speed.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
let production=false,created=0,advanced=0,app=0;const files=new Map();
const folder={getId:()=> 'isolated-only',createFile(blob){app++;return store(blob.name,blob);}};
function store(name,blob){const id=String(files.size);const file={getId:()=>id,getSize:()=>blob.bytes.length,getName:()=>name,getMimeType:()=>blob.type,getParents:()=>{let n=0;return {hasNext:()=>n===0,next:()=>{n++;return folder;}};}};files.set(id,file);return file;}
const context=vm.createContext({console:{log(){}},PropertiesService:{getScriptProperties:()=>({getProperty:()=>production?'production-present':null})},
 DriveApp:{createFolder(){created++;return folder;},getFileById:id=>files.get(id)},Utilities:{newBlob:(bytes,type,name)=>({bytes,type,name})},
 Drive:{Files:{create(metadata,blob){advanced++;assert.deepEqual(Array.from(metadata.parents),['isolated-only']);return {id:store(metadata.name,blob).getId()};}}}});
vm.runInContext(fs.readFileSync('Tools/GalleryPerformance/DriveCreateBenchmark.gs','utf8'),context);
for(const config of [null,{}, {confirmIsolated:true,photoCount:7,guests:1}])assert.throws(()=>context.benchmarkIsolatedDriveCreate(config));
production=true;assert.throws(()=>context.benchmarkIsolatedDriveCreate({confirmIsolated:true,photoCount:1,guests:1}));assert.equal(created,0);
production=false;const rows=context.benchmarkIsolatedDriveCreate({confirmIsolated:true,photoCount:3,guests:5});
assert.equal(rows.length,10);assert.equal(advanced,15);assert.equal(app,15);assert.equal(created,1);assert.equal(rows[0].bytes,900000);
console.log('Isolated Drive create experiment contract passed; no real Drive latency measured.');
