import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';import fs from 'node:fs';import crypto from 'node:crypto';
const source=fs.readFileSync(new URL('../Code.gs',import.meta.url),'utf8'),secret='synthetic-server-key-long-enough-for-contract-tests';
function fixture(){const properties={RECEIPTS_HMAC_SECRET:secret,RECEIPTS_ROOT_ID:'synthetic-private-root'};const context=vm.createContext({PropertiesService:{getScriptProperties:()=>({getProperty:k=>properties[k],setProperty:(k,v)=>properties[k]=v})},Utilities:{Charset:{UTF_8:'utf8'},base64Encode:v=>Buffer.from(v).toString('base64'),base64Decode:v=>[...Buffer.from(v,'base64')],newBlob:v=>({getDataAsString:()=>Buffer.from(v).toString()}),computeHmacSha256Signature:(v,k)=>[...crypto.createHmac('sha256',k).update(v).digest()]},ContentService:{MimeType:{JSON:'json'},createTextOutput:text=>({text,setMimeType(){return this;}})}});vm.runInContext(source,context);return {context,properties};}
function envelope(operation='store',payload={}){const e={v:1,keyId:'receipt-v1',timestamp:new Date().toISOString(),nonce:crypto.randomUUID(),operationId:crypto.randomUUID(),operation,payloadB64:Buffer.from(JSON.stringify(payload)).toString('base64')};return sign(e);}
function sign(e){e.signature=crypto.createHmac('sha256',secret).update(['v1',e.keyId,e.timestamp,e.nonce,e.operationId,e.operation,e.payloadB64].join('\n')).digest('hex');return e;}
const invoke=(c,e)=>JSON.parse(c.doPost({postData:{contents:JSON.stringify(e)}}).text);
test('readiness signs only an owner-private folder that can receive files and performs no write',()=>{
    const {context:c}=fixture();
    let writable=true, ownerOnly=true;
    c.receiptDrive_=(p,options)=>{
        assert.equal(options,undefined);
        assert.match(p,/permissions\(type,role\)/);
        return {id:'synthetic-private-root',mimeType:'application/vnd.google-apps.folder',
            permissions:ownerOnly?[{type:'user',role:'owner'}]:[],capabilities:{canAddChildren:writable}};
    };
    const request=envelope('ready');
    const result=invoke(c,request);
    assert.deepEqual(JSON.parse(Buffer.from(result.payloadB64,'base64')),{ok:true,ready:true});
    assert.equal(result.signature,crypto.createHmac('sha256',secret).update(request.operationId+'\nready\n'+result.payloadB64).digest('hex'));
    writable=false;assert.equal(invoke(c,request).code,'invalid_private_root');
    ownerOnly=false;assert.equal(invoke(c,request).code,'unsafe_permissions');
});
test('unsigned, stale and modified envelopes cannot touch Drive',()=>{const {context:c}=fixture();c.assertReceiptPrivate_=()=>assert.fail('unauthorized Drive access');const unsigned=envelope();delete unsigned.signature;assert.equal(invoke(c,unsigned).code,'unauthorized');const expired=sign({...envelope(),timestamp:'2000-01-01T00:00:00.000Z'});assert.equal(invoke(c,expired).code,'request_expired');const altered={...envelope(),payloadB64:'e30='};altered.signature='0'.repeat(64);assert.equal(invoke(c,altered).code,'unauthorized');});
test('the complete twice-base64 envelope accepts a 2 MiB image and signs its exact response',()=>{const {context:c}=fixture();let calls=0;c.assertReceiptPrivate_=()=>{};c.storePrivateReceipt_=(_root,id,p)=>{calls++;assert.equal(p.base64.length,2796204);return {ok:true,fileId:'private-file',private:true};};const e=envelope('store',{base64:Buffer.alloc(2097152).toString('base64')});assert.ok(JSON.stringify(e).length>3000000);const r=invoke(c,e);assert.equal(calls,1);assert.equal(r.operationId,e.operationId);assert.equal(r.signature,crypto.createHmac('sha256',secret).update(e.operationId+'\nstore\n'+r.payloadB64).digest('hex'));});
test('ACL verification rejects every public, group, domain and secondary-user grant',()=>{for(const extra of [{type:'anyone',role:'reader'},{type:'domain',role:'reader'},{type:'group',role:'reader'},{type:'user',role:'reader'}]){const {context:c}=fixture();c.receiptDrive_=()=>({id:'synthetic-private-root',trashed:false,permissions:[{type:'user',role:'owner'},extra]});assert.throws(()=>c.assertReceiptPrivate_('synthetic-private-root'),/unsafe_permissions/);}});
test('retention is inert until explicitly established; eligible Trash remains recoverable and idempotent',()=>{const {context:c,properties}=fixture();c.receiptJournal_=()=>({value:{fileId:'synthetic-file-id',createdAt:Date.now()-2*86400000,parentId:'synthetic-parent'}});let mutations=0;c.assertReceiptPrivate_=()=>({parents:['synthetic-parent'],trashed:mutations>0});c.receiptDrive_=(p,o)=>{assert.equal(o.payload.trashed,true);mutations++;};assert.throws(()=>c.trashPrivateReceipt_('root','id',{fileId:'synthetic-file-id',retentionApproved:true}),/retention_not_approved/);assert.throws(()=>c.establishReceiptRetention_({days:1,approved:false}),/retention_not_approved/);c.establishReceiptRetention_({days:1,approved:true});assert.equal(properties.RECEIPT_RETENTION_DAYS,'1');for(let i=0;i<2;i++)assert.equal(c.trashPrivateReceipt_('root','id',{fileId:'synthetic-file-id',retentionApproved:true}).trashed,true);assert.equal(mutations,1);assert.ok(!source.includes('ScriptApp.newTrigger'));});
test('canonical project has no secret initializer, gallery writes or sharing mutations',()=>{assert.ok(!source.includes('configureReceiptsForOwner'));assert.ok(!source.includes('.setSharing('));assert.ok(!/permissions[^\n]{0,80}method\s*:\s*['"]post/i.test(source));assert.equal(fixture().context.doGet().text,'Private receipt service.');});

test('LIVE and TEST keys cannot cross receipt roots or retention settings', () => {
    const {context,properties} = fixture();
    const liveKey = 'separate-production-synthetic-secret-for-tests';
    properties.RECEIPTS_HMAC_SECRET_LIVE = liveKey;
    properties.RECEIPTS_ROOT_ID_LIVE = 'separate-live-root';
    const checkedRoots = [];
    context.assertReceiptPrivate_ = root => checkedRoots.push(root);
    const request = sign({...envelope('retention',{approved:true,days:5}),keyId:'receipt-live-v1'});
    assert.equal(invoke(context,request).code,'unauthorized');
    assert.deepEqual(checkedRoots,[]);
    request.signature = crypto.createHmac('sha256',liveKey)
        .update(['v1',request.keyId,request.timestamp,request.nonce,request.operationId,request.operation,request.payloadB64].join('\n')).digest('hex');
    assert.equal(invoke(context,request).operationId,request.operationId);
    assert.deepEqual(checkedRoots,['separate-live-root']);
    assert.equal(properties.RECEIPT_RETENTION_DAYS_LIVE,'5');
    assert.equal(properties.RECEIPT_RETENTION_DAYS,undefined);
    properties.RECEIPTS_ROOT_ID_LIVE = properties.RECEIPTS_ROOT_ID;
    assert.equal(invoke(context,request).code,'invalid_private_root');
});

const ownerACL = [{type:'user',role:'owner'}];
const privateRoot = 'synthetic-private-root';
const parentID = 'synthetic-parent';
const mediaID = 'synthetic-drive-media';
const mediaBytes = Buffer.from('fictional image bytes for the bridge test');
const mediaHash = crypto.createHash('sha256').update(mediaBytes).digest('hex');
const fileProof = {id:mediaID,trashed:false,mimeType:'image/png',parents:[parentID],
    permissions:ownerACL,size:String(mediaBytes.length),sha256Checksum:mediaHash};
const uploadPayload = {checkoutId:crypto.randomUUID(),year:'2026',month:'11',date:'2026-11-25',eventId:'synthetic-receipt-event',
    sha256:mediaHash,mimeType:'image/png',bytes:mediaBytes.length,base64:mediaBytes.toString('base64')};

function mediaFixture({loseCreateResponse=false, existingProof=null}={}) {
    const {context:c}=fixture();
    const operation=envelope('store',uploadPayload);
    const calls=[];
    let locked=false;
    let media=existingProof;
    let value=existingProof?{id:operation.operationId,checkoutId:uploadPayload.checkoutId,fileId:mediaID,parentId:parentID,
        mimeType:uploadPayload.mimeType,sha256:mediaHash,bytes:mediaBytes.length,createdAt:1}:null;
    c.Utilities.DigestAlgorithm={SHA_256:'sha256'};
    c.Utilities.computeDigest=(algorithm,bytes)=>[...crypto.createHash(algorithm).update(Buffer.from(bytes)).digest()];
    const file={
        getId:()=> 'synthetic-journal-file',
        getBlob:()=>({getDataAsString:()=>JSON.stringify(value)}),
        setContent:encoded=>{assert.ok(locked);value=JSON.parse(encoded);calls.push('confirmation');}
    };
    c.LockService={getScriptLock:()=>({
        tryLock:()=>{assert.equal(locked,false);locked=true;return true;},
        releaseLock:()=>{assert.equal(locked,true);locked=false;}
    })};
    c.receiptFolder_=()=>{assert.ok(locked);return parentID;};
    c.receiptJournal_=()=> {
        assert.ok(locked);
        return {file:value?file:null,value,folder:{createFile:(_name,encoded)=>{
            assert.ok(locked);value=JSON.parse(encoded);calls.push('reservation');return file;
        }}};
    };
    c.receiptDrive_=(route)=>{
        assert.match(route,/generateIds/);assert.ok(locked);return {ids:[mediaID]};
    };
    c.assertReceiptPrivate_=(id)=>{
        if(id===mediaID){
            calls.push('readback');
            return c.assertReceiptOwnerOnly_(media);
        }
        if(id===parentID) assert.equal(locked,false);
        if(id==='synthetic-journal-file') assert.equal(locked,true);
        return {id,permissions:ownerACL};
    };
    c.Drive={Files:{
        create:(metadata,blob,query)=>{
            calls.push('create');
            assert.equal(locked,false);
            assert.equal(value.fileId,mediaID);
            assert.equal(metadata.id,mediaID);assert.equal(metadata.parents[0],parentID);
            assert.match(query.fields,/sha256Checksum/);
            assert.deepEqual(Buffer.from(blob.getDataAsString()),mediaBytes);
            if(media)throw Error('conflict');
            media=fileProof;
            if(loseCreateResponse)throw Error('response lost');
            return media;
        },
        update:(_metadata,id)=>{
            calls.push('update');
            assert.equal(locked,false);assert.equal(id,mediaID);
            media=fileProof;return media;
        }
    }};
    return {context:c,operation,calls,journal:()=>value};
}

test('new media uses one Drive create and its returned proof outside the reservation lock',()=>{
    const {context,operation,calls,journal}=mediaFixture();
    const result=invoke(context,operation);
    assert.equal(JSON.parse(Buffer.from(result.payloadB64,'base64')).fileId,mediaID);
    assert.deepEqual(calls,['reservation','create','confirmation']);
    const first=journal().storedAt;
    const replay=invoke(context,operation);
    assert.equal(JSON.parse(Buffer.from(replay.payloadB64,'base64')).fileId,mediaID);
    assert.deepEqual(calls,['reservation','create','confirmation','readback']);
    assert.equal(journal().storedAt,first);
});

test('a lost create response reads the reserved file and completes the same journal',()=>{
    const {context,operation,calls,journal}=mediaFixture({loseCreateResponse:true});
    const stored=invoke(context,operation);
    assert.equal(JSON.parse(Buffer.from(stored.payloadB64,'base64')).fileId,mediaID);
    assert.deepEqual(calls,['reservation','create','readback','confirmation']);
    assert.ok(journal().storedAt);
});

test('an old empty private reservation can finish, while mismatched or shared media stays unconfirmed',()=>{
    const legacy=mediaFixture({existingProof:{...fileProof,size:'0',sha256Checksum:undefined}});
    assert.ok(invoke(legacy.context,legacy.operation).signature);
    assert.deepEqual(legacy.calls,['create','readback','update','confirmation']);
    const mismatch=mediaFixture({existingProof:{...fileProof,sha256Checksum:'f'.repeat(64)}});
    assert.equal(invoke(mismatch.context,mismatch.operation).code,'storage_mismatch');
    assert.deepEqual(mismatch.calls,['create','readback']);
    assert.equal(mismatch.journal().storedAt,undefined);
    const shared=mediaFixture({existingProof:{...fileProof,permissions:[...ownerACL,{role:'reader',type:'anyone'}]}});
    assert.equal(invoke(shared.context,shared.operation).code,'unsafe_permissions');
    assert.equal(shared.journal().storedAt,undefined);
});

test('folder lookup checks parent and ACL from the same metadata response',()=>{
    const {context:c}=fixture();
    let output={files:[{id:parentID,mimeType:'application/vnd.google-apps.folder',parents:[privateRoot],permissions:ownerACL}]};
    c.receiptDrive_=(route)=>{
        assert.ok(route.startsWith('drive/v3/files?q='));
        assert.ok(decodeURIComponent(route).includes("name='Events'"));
        assert.match(route,/permissions\(type,role\)/);
        return output;
    };
    assert.equal(c.receiptFolder_(privateRoot,'Events'),parentID);
    output.files[0].parents=['wrong-parent'];
    assert.throws(()=>c.receiptFolder_(privateRoot,'Events'),/parent_changed/);
    output.nextPageToken='more-folders';
    assert.throws(()=>c.receiptFolder_(privateRoot,'Events'),/duplicate_private_folder/);
});

test('omitted inline permissions require a complete explicit ACL read',()=>{
    const {context:c}=fixture();
    let paginated=false;
    c.receiptDrive_=(route)=>{
        if(route.includes('/permissions?'))return {permissions:ownerACL,nextPageToken:paginated?'more':undefined};
        return {id:privateRoot,trashed:false};
    };
    assert.equal(c.assertReceiptPrivate_(privateRoot).id,privateRoot);
    paginated=true;
    assert.throws(()=>c.assertReceiptPrivate_(privateRoot),/unsafe_permissions/);
});

test('a warm destination validates all four locations in parallel and rediscovers stale paths',()=>{
    const {context:c}=fixture();
    const ids=['synthetic-year','synthetic-month','synthetic-events','synthetic-target'];
    let saved=JSON.stringify(ids), coldLookups=0, parallelLookups=0, stale=false;
    c.Utilities.DigestAlgorithm={SHA_256:'sha256'};
    c.Utilities.computeDigest=(algorithm,text)=>[...crypto.createHash(algorithm).update(text).digest()];
    c.CacheService={getScriptCache:()=>({get:()=>saved,put:(_key,value)=>{saved=value;}})};
    c.ScriptApp={getOAuthToken:()=> 'fictional-drive-token'};
    c.UrlFetchApp={fetchAll:requests=>{
        parallelLookups++;
        assert.equal(requests.length,4);
        return requests.map((request,i)=>{
            assert.ok(decodeURIComponent(request.url).includes("'"+(i?ids[i-1]:privateRoot)+"' in parents"));
            const file={id:stale&&i===3?'synthetic-moved-target':ids[i],mimeType:'application/vnd.google-apps.folder',
                parents:[i?ids[i-1]:privateRoot],permissions:ownerACL};
            return {getResponseCode:()=>200,getContentText:()=>JSON.stringify({files:[file]})};
        });
    }};
    c.receiptFolder_=()=>ids[coldLookups++];
    assert.equal(c.receiptDestination_(privateRoot,uploadPayload),ids[3]);
    assert.equal(coldLookups,0);
    assert.equal(parallelLookups,1);
    stale=true;
    assert.equal(c.receiptDestination_(privateRoot,uploadPayload),ids[3]);
    assert.equal(coldLookups,4);
});

test('a cached destination cannot bypass unsafe Drive permissions',()=>{
    const {context:c}=fixture();
    const ids=['synthetic-year','synthetic-month','synthetic-events','synthetic-target'];
    c.Utilities.DigestAlgorithm={SHA_256:'sha256'};
    c.Utilities.computeDigest=(algorithm,text)=>[...crypto.createHash(algorithm).update(text).digest()];
    c.CacheService={getScriptCache:()=>({get:()=>JSON.stringify(ids),put:()=>assert.fail('unsafe path cached')})};
    c.ScriptApp={getOAuthToken:()=> 'fictional-drive-token'};
    const makeFile=i=>({id:ids[i],mimeType:'application/vnd.google-apps.folder',parents:[i?ids[i-1]:privateRoot],
        permissions:i===2?[...ownerACL,{type:'anyone',role:'reader'}]:ownerACL});
    c.UrlFetchApp={fetchAll:requests=>requests.map((_,i)=>({
        getResponseCode:()=>200,getContentText:()=>JSON.stringify({files:[makeFile(i)]})
    }))};
    let coldLookups=0;
    c.receiptDrive_=()=>({files:[makeFile(coldLookups++)]});
    assert.throws(()=>c.receiptDestination_(privateRoot,uploadPayload),/unsafe_permissions/);
    assert.equal(coldLookups,3);
});
