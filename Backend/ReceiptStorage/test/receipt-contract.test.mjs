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
        return p.includes('/permissions?') ? {permissions:ownerOnly?[{type:'user',role:'owner'}]:[]}
            : {mimeType:'application/vnd.google-apps.folder',capabilities:{canAddChildren:writable}};
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
test('ACL verification rejects every public, group, domain and secondary-user grant',()=>{for(const extra of [{type:'anyone',role:'reader'},{type:'domain',role:'reader'},{type:'group',role:'reader'},{type:'user',role:'reader'}]){const {context:c}=fixture();c.receiptDrive_=p=>p.includes('permissions')?{permissions:[{type:'user',role:'owner'},extra]}:{trashed:false};assert.throws(()=>c.assertReceiptPrivate_('synthetic-private-root'),/unsafe_permissions/);}});
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
