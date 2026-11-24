import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac,createHash,randomUUID} from 'node:crypto';
import {deflateSync} from 'node:zlib';
import {createHarness,TOKENS,activePaidEvent,newOrder,applyMigrations} from './support/harness.js';
const secret='synthetic-receipt-server-secret-for-testing-only';
const signing=value=>createHmac('sha256',secret).update(value).digest('hex');
const sha=value=>createHash('sha256').update(value).digest('hex');
const png='iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGNoUDAAIgYIBQAYDgNB5YZ+PAAAAABJRU5ErkJggg==';
class PrivateStorage {
    constructor(){this.files=new Map();this.calls=0;this.loseNext=false;this.unsafe=false;this.badSignature=false;}
    async handle(request){
        if(new URL(request.url).hostname!=='script.google.com')return null;
        const e=await request.json();assert.equal(e.signature,signing(['v1',e.keyId,e.timestamp,e.nonce,e.operationId,e.operation,e.payloadB64].join('\n')));
        const p=JSON.parse(Buffer.from(e.payloadB64,'base64').toString());this.calls++;
        if(e.operation==='store'){
            if(!this.files.has(e.operationId))this.files.set(e.operationId,p);
            else assert.equal(this.files.get(e.operationId).sha256,p.sha256);
            if(this.loseNext){this.loseNext=false;throw Error('lost acknowledgment after storing');}
        }
        const result=e.operation==='retention'?{ok:true,days:p.days}:e.operation==='trash'?{ok:true,trashed:true}:e.operation==='read'?{ok:true,base64:this.files.get(e.operationId).base64}:{ok:true,private:!this.unsafe,sha256:p.sha256,bytes:p.bytes,fileId:'private-'+e.operationId,folderURL:'https://drive.google.com/drive/folders/private-fixture'};
        const payloadB64=Buffer.from(JSON.stringify(result)).toString('base64');return Response.json({operationId:e.operationId,operation:e.operation,payloadB64,signature:this.badSignature?'0'.repeat(64):signing(e.operationId+'\n'+e.operation+'\n'+payloadB64)});
    }
}
async function fixture(body,overrides={}){
    const storage=new PrivateStorage();const h=await createHarness({bindings:{MANUAL_CHECKOUT_ENABLED:'true',MANUAL_TOKEN_SECRET:'synthetic-capability-key-of-at-least-32-characters',RECEIPTS_SCRIPT_URL:'https://script.google.com/macros/s/PRIVATE_STAGED/exec',RECEIPTS_HMAC_SECRET:secret,...overrides},receiptService:storage});
    try{await body(h,storage);}finally{await h.dispose();}
}
async function checkout(h,policy='OPTIONAL',options={}){
    const receiverId=options.receiverId||randomUUID();
    if(!options.receiverId){const r=await h.request('POST','/v2/admin/receiving-accounts',{token:TOKENS.operator,body:{id:receiverId,provider:'Synthetic account',recipient:'Example recipient',identifier:'TEST-ACCOUNT',instructions:'Synthetic test only',enabled:true,permittedUseConfirmed:true}});assert.equal(r.status,200);}
    const body={localCheckoutId:randomUUID(),sessionId:randomUUID(),eventId:'evt-synthetic',eventName:'Synthetic event',runId:'run-synthetic',format:'solo',copies:3,unitPriceCentavos:2500,method:'MANUAL_DIGITAL',mode:'cashAndDigital',receiptPolicy:policy,receiverId,...options};
    body.snapshotHash=sha([body.localCheckoutId,body.sessionId,body.eventId,body.runId||'',body.format,String(body.copies),String(body.unitPriceCentavos),body.method,body.receiptPolicy,body.receiverId||'',body.mode].join('\n'));
    const r=await h.request('POST','/v2/booth/checkouts',{body});assert.equal(r.status,201,r.text);
    return {body,status:r.json,auth:{token:null,headers:{authorization:'Checkout '+new URL(r.json.checkoutURL).hash.slice(3)}}};
}
test('all receipt policies keep acknowledgment, stored evidence and print authority separate',()=>fixture(async h=>{
    for(const policy of ['ACK_ONLY','OPTIONAL','REQUIRED']){
        const c=await checkout(h,policy);const ack=await h.request('POST','/v2/guest/acknowledgments',{...c.auth,body:{snapshotHash:c.body.snapshotHash}});
        assert.equal(ack.status,200);assert.ok(ack.json.acknowledgedAt);assert.equal(ack.json.receipt,null);assert.equal(ack.json.entitlement,undefined);
        const stored=await h.request('POST','/v2/guest/receipts',{...c.auth,body:{snapshotHash:c.body.snapshotHash,mimeType:'image/png',base64:png}});assert.equal(stored.status,200,stored.text);
        const status=await h.request('GET','/v2/booth/checkouts/'+c.status.id);assert.equal(status.json.receipt.snapshotHash,c.body.snapshotHash);
        assert.equal((await h.all('SELECT id FROM entitlements')).length,0);assert.equal((await h.all('SELECT id FROM print_batches')).length,0);
    }
}));
test('immutable replay returns the same capability; changed amount/copies/session cannot replace it',()=>fixture(async h=>{
    const c=await checkout(h);const replay=await h.request('POST','/v2/booth/checkouts',{body:c.body});assert.equal(replay.status,200);assert.equal(replay.json.checkoutURL,c.status.checkoutURL);
    const changed={...c.body,copies:4};changed.snapshotHash=sha([changed.localCheckoutId,changed.sessionId,changed.eventId,changed.runId,changed.format,'4','2500',changed.method,changed.receiptPolicy,changed.receiverId,changed.mode].join('\n'));
    assert.equal((await h.request('POST','/v2/booth/checkouts',{body:changed})).status,409);
    assert.equal((await h.request('GET','/v2/booth/checkouts/'+c.status.id,{token:TOKENS.booth2})).status,404);
    assert.equal((await h.request('GET','/v2/admin/checkouts/'+c.status.id,{token:TOKENS.otherAccount})).status,404);
}));
test('lost storage acknowledgment and concurrent duplicate submissions retain one file and receipt identity',()=>fixture(async(h,storage)=>{
    const c=await checkout(h,'REQUIRED');storage.loseNext=true;const request={...c.auth,body:{snapshotHash:c.body.snapshotHash,mimeType:'image/png',base64:png}};
    assert.equal((await h.request('POST','/v2/guest/receipts',request)).status,503);
    const replies=await Promise.all([h.request('POST','/v2/guest/receipts',request),h.request('POST','/v2/guest/receipts',request)]);
    assert.ok(replies.every(r=>r.status===200));assert.equal(replies[0].json.receiptId,replies[1].json.receiptId);
    assert.equal(storage.files.size,1);assert.equal((await h.all('SELECT id FROM manual_receipts')).length,1);
}));
test('closed or expired acknowledgment is review only; late optional receipt stays with the original session',()=>fixture(async h=>{
    const c=await checkout(h);await h.request('POST','/v2/booth/checkouts/'+c.status.id+'/facts',{body:{snapshotHash:c.body.snapshotHash,closedAt:new Date().toISOString()}});
    assert.equal((await h.request('POST','/v2/guest/acknowledgments',{...c.auth,body:{snapshotHash:c.body.snapshotHash}})).status,409);
    const late=await h.request('POST','/v2/guest/receipts',{...c.auth,body:{snapshotHash:c.body.snapshotHash,mimeType:'image/png',base64:png}});assert.equal(late.status,200);
    const row=await h.one('SELECT acknowledged_at,late_acknowledged_at,session_id FROM manual_checkouts WHERE id=?',c.status.id);assert.equal(row.acknowledged_at,null);assert.ok(row.late_acknowledged_at);assert.equal(row.session_id,c.body.sessionId);
    const d=await checkout(h);await h.db.prepare('UPDATE manual_checkouts SET expires_at=? WHERE id=?').bind('2000-01-01T00:00:00.000Z',d.status.id).run();
    assert.equal((await h.request('POST','/v2/guest/acknowledgments',{...d.auth,body:{snapshotHash:d.body.snapshotHash}})).status,409);
}));
test('public capability cannot list, preview, administer, claim legacy entitlements or use another snapshot',()=>fixture(async h=>{
    const c=await checkout(h),d=await checkout(h);
    for(const path of ['/v2/admin/records','/v2/admin/receipts/'+randomUUID(),'/v1/admin/events'])assert.equal((await h.request('GET',path,c.auth)).status,401);
    assert.equal((await h.request('POST','/v1/entitlements/anything/claim',{...c.auth,body:{}})).status,401);
    assert.equal((await h.request('POST','/v2/guest/receipts',{...c.auth,body:{snapshotHash:d.body.snapshotHash,mimeType:'image/png',base64:png}})).status,409);
    assert.equal((await h.request('POST','/v2/guest/status',{token:null,headers:{authorization:'Checkout '+c.status.id+'.'+'0'.repeat(64)},body:{}})).status,401);
    assert.equal((await h.request('POST','/v2/guest/status',{...c.auth,headers:{...c.auth.headers,origin:'https://untrusted.example'},body:{}})).status,403);
}));
test('private storage proof is mandatory; malformed images and public ACL response are rejected',()=>fixture(async(h,storage)=>{
    const c=await checkout(h,'REQUIRED');storage.unsafe=true;
    assert.equal((await h.request('POST','/v2/guest/receipts',{...c.auth,body:{snapshotHash:c.body.snapshotHash,mimeType:'image/png',base64:png}})).status,502);
    assert.equal((await h.request('GET','/v2/booth/checkouts/'+c.status.id)).json.receipt,null);
    for(const mime of ['image/svg+xml','text/html','image/jpeg'])assert.equal((await h.request('POST','/v2/guest/receipts',{...c.auth,body:{snapshotHash:c.body.snapshotHash,mimeType:mime,base64:Buffer.from('<html>not a receipt</html>').toString('base64')}})).status,422);
}));
test('independent review is append-only and idempotent without changing original price or acknowledgment',()=>fixture(async h=>{
    const c=await checkout(h);const review={id:randomUUID(),outcome:'FUNDS_CONFIRMED',confirmedCentavos:7000,note:'Synthetic independent account check'};
    const path='/v2/admin/checkouts/'+c.status.id+'/reviews';assert.equal((await h.request('POST',path,{token:TOKENS.boothOnly,body:review})).status,403);
    assert.equal((await h.request('POST',path,{token:TOKENS.operator,body:review})).status,200);assert.equal((await h.request('POST',path,{token:TOKENS.operator,body:review})).status,200);
    assert.equal((await h.request('POST',path,{token:TOKENS.operator,body:{...review,confirmedCentavos:7500}})).status,409);
    const rows=await h.request('GET','/v2/admin/records',{token:TOKENS.operator});assert.equal(rows.json.records[0].confirmed_centavos,7000);assert.equal(rows.json.records[0].acknowledged_at,null);
    assert.equal(JSON.parse(rows.json.records[0].snapshot_json).unitPriceCentavos,2500);assert.equal((await h.all('SELECT id FROM manual_reviews')).length,1);
}));
test('unconfigured or disabled digital service cannot accept mobile checkouts',async()=>{
    await fixture(async h=>{assert.equal((await h.request('POST','/v2/booth/checkouts',{body:{}})).status,503);},{MANUAL_CHECKOUT_ENABLED:'false'});
    await fixture(async h=>{const page=await h.request('GET','/checkout',{token:null});assert.equal(page.status,200);assert.ok(page.headers.get('content-security-policy').includes("frame-ancestors 'none'"));assert.ok(!page.text.includes('https://'));});
});

function chunk(type,data){const name=Buffer.from(type),len=Buffer.alloc(4);len.writeUInt32BE(data.length);let c=0xffffffff;for(const byte of Buffer.concat([name,data])){c^=byte;for(let i=0;i<8;i++)c=(c>>>1)^((c&1)?0xedb88320:0);}const crc=Buffer.alloc(4);crc.writeUInt32BE((c^0xffffffff)>>>0);return Buffer.concat([len,name,data,crc]);}
function image(color=0,metadata=false){const head=Buffer.alloc(13);head.writeUInt32BE(2);head.writeUInt32BE(2,4);head[8]=8;head[9]=2;return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',head),...(metadata?[chunk('tEXt',Buffer.from('GPS\0SYNTHETIC-PRIVATE-METADATA'))]:[]),chunk('IDAT',deflateSync(Buffer.from([0,color,0,0,0,0,0,0,0,0,0,0,0,0]))),chunk('IEND',Buffer.alloc(0))]).toString('base64');}
test('normalized dedup strips metadata and enforces size and atomic three-version limits',()=>fixture(async(h,storage)=>{
    const c=await checkout(h);const upload=base64=>h.request('POST','/v2/guest/receipts',{...c.auth,body:{snapshotHash:c.body.snapshotHash,mimeType:'image/png',base64}});
    const first=await upload(image(0,true)),equivalent=await upload(image(0));assert.equal(first.status,200);assert.equal(first.json.receiptId,equivalent.json.receiptId);assert.equal(storage.files.size,1);
    assert.ok(!Buffer.from([...storage.files.values()][0].base64,'base64').includes(Buffer.from('SYNTHETIC-PRIVATE-METADATA')));
    const concurrent=await Promise.all([upload(image(1)),upload(image(2)),upload(image(3)),upload(image(4))]);assert.equal(concurrent.filter(r=>r.status===200).length,2);assert.ok(concurrent.every(r=>[200,429].includes(r.status)));assert.equal((await h.one('SELECT COUNT(*) n FROM manual_receipts WHERE checkout_id=?',c.status.id)).n,3);
    const d=await checkout(h);assert.equal((await h.request('POST','/v2/guest/receipts',{...d.auth,body:{snapshotHash:d.body.snapshotHash,mimeType:'image/png',base64:Buffer.alloc(2097153).toString('base64')}})).status,422);
}));
test('rate limiting, expiration and forged storage proof fail closed',()=>fixture(async(h,storage)=>{
    const c=await checkout(h,'REQUIRED');storage.badSignature=true;
    assert.equal((await h.request('POST','/v2/guest/receipts',{...c.auth,body:{snapshotHash:c.body.snapshotHash,mimeType:'image/png',base64:png}})).status,503);
    assert.equal((await h.request('GET','/v2/booth/checkouts/'+c.status.id)).json.receipt,null);
    const d=await checkout(h);for(let i=0;i<12;i++)assert.equal((await h.request('POST','/v2/guest/acknowledgments',{...d.auth,body:{snapshotHash:d.body.snapshotHash}})).status,200);
    assert.equal((await h.request('POST','/v2/guest/acknowledgments',{...d.auth,body:{snapshotHash:d.body.snapshotHash}})).status,429);
    await h.db.prepare('UPDATE manual_checkouts SET receipt_expires_at=? WHERE id=?').bind('2000-01-01T00:00:00.000Z',c.status.id).run();assert.equal((await h.request('POST','/v2/guest/status',{...c.auth,body:{}})).status,410);
}));
test('retention requires an explicit policy and eligible age, keeps payment association and audits Trash',()=>fixture(async h=>{
    const c=await checkout(h);const uploaded=await h.request('POST','/v2/guest/receipts',{...c.auth,body:{snapshotHash:c.body.snapshotHash,mimeType:'image/png',base64:png}});const path='/v2/admin/receipts/'+uploaded.json.receiptId+'/trash';const body={approved:true,reason:'Synthetic eligible retention review'};
    assert.equal((await h.request('POST',path,{token:TOKENS.operator,body})).status,409);
    assert.equal((await h.request('POST','/v2/admin/retention',{token:TOKENS.boothOnly,body:{days:1,approved:true}})).status,403);
    assert.equal((await h.request('POST','/v2/admin/retention',{token:TOKENS.operator,body:{days:1,approved:false}})).status,422);
    assert.equal((await h.request('POST','/v2/admin/retention',{token:TOKENS.operator,body:{days:1,approved:true}})).status,200);
    assert.equal((await h.request('POST',path,{token:TOKENS.operator,body})).status,409);
    await h.db.prepare('UPDATE manual_receipts SET stored_at=? WHERE id=?').bind('2000-01-01T00:00:00.000Z',uploaded.json.receiptId).run();
    for(let i=0;i<2;i++)assert.equal((await h.request('POST',path,{token:TOKENS.operator,body})).status,200);
    assert.equal((await h.request('GET','/v2/admin/receipts/'+uploaded.json.receiptId,{token:TOKENS.operator})).status,410);
    assert.equal((await h.one('SELECT COUNT(*) n FROM manual_receipt_trash_audit')).n,1);assert.ok((await h.request('GET','/v2/booth/checkouts/'+c.status.id)).json.receipt.trashedAt);
}));
test('physical imports keep original session and copy bounds and never grant print authority',()=>fixture(async h=>{
    const c=await checkout(h),path='/v2/booth/checkouts/'+c.status.id+'/facts';const e={id:'entry-1',batchID:'batch-1',sessionID:c.body.sessionId,copyIndex:1,localState:'uncertain',receiptFingerprint:'a'.repeat(64),updatedAt:new Date().toISOString()};const body={snapshotHash:c.body.snapshotHash,printEvidence:[e]};
    assert.equal((await h.request('POST',path,{body})).status,200);assert.equal((await h.request('POST',path,{body})).status,200);
    for(const change of [{sessionID:'other-session'},{copyIndex:4},{localState:'notStarted'},{receiptFingerprint:'changed'}])assert.equal((await h.request('POST',path,{body:{...body,printEvidence:[{...e,...change}]}})).status,409);
    assert.equal((await h.one('SELECT COUNT(*) n FROM manual_print_evidence')).n,1);assert.equal((await h.one('SELECT COUNT(*) n FROM entitlements')).n,0);
}));
test('0009 preserves a populated legacy entitlement and payment method',async()=>{
    const h=await createHarness({migrateUpTo:8});try{
        const event=await activePaidEvent(h),order=await newOrder(h,event);assert.equal((await h.request('POST','/v1/orders/'+order.order.id+'/cash-declaration')).status,200);
        const tables=['orders','payment_attempts','entitlements','events','event_policy_revisions'],before={};for(const t of tables)before[t]=await h.all('SELECT * FROM '+t+' ORDER BY rowid');
        await applyMigrations(h.db,['0009_manual_payments.sql']);for(const t of tables)assert.deepEqual(await h.all('SELECT * FROM '+t+' ORDER BY rowid'),before[t]);assert.deepEqual(await h.all('PRAGMA foreign_key_check'),[]);
    }finally{await h.dispose();}
});

test('delayed offline synchronization cannot extend the original guest acknowledgment window',()=>fixture(async h=>{
    const c=await checkout(h,'OPTIONAL',{createdAt:new Date(Date.now()-31*60000).toISOString()});
    assert.equal((await h.request('POST','/v2/guest/acknowledgments',{...c.auth,body:{snapshotHash:c.body.snapshotHash}})).status,409);
    assert.equal((await h.request('GET','/v2/booth/checkouts/'+c.status.id)).json.acknowledgedAt,null);
}));

test('concurrent booth closure and mobile acknowledgment retain either original or late claim',()=>fixture(async h=>{
    for(let i=0;i<6;i++){
        const c=await checkout(h);const results=await Promise.all([
            h.request('POST','/v2/guest/acknowledgments',{...c.auth,body:{snapshotHash:c.body.snapshotHash}}),
            h.request('POST','/v2/booth/checkouts/'+c.status.id+'/facts',{body:{snapshotHash:c.body.snapshotHash,closedAt:new Date().toISOString()}})
        ]);assert.ok([200,409].includes(results[0].status));assert.equal(results[1].status,200);
        const row=await h.one('SELECT acknowledged_at,late_acknowledged_at,closed_at FROM manual_checkouts WHERE id=?',c.status.id);assert.ok(row.closed_at);assert.ok(row.acknowledged_at||row.late_acknowledged_at,'No payment claim lost in closure race');
    }
}));
