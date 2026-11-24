import { mobileCheckoutPage } from './mobile-checkout.js';
import { normalizeReceipt, RECEIPT_MAX_BYTES } from './receipt-image.js';

const encoder=new TextEncoder(), formats=new Set(['solo','duo','grid','gridSix','strip','passport','photoPass']);
const noStore={'content-type':'application/json; charset=utf-8','cache-control':'no-store','referrer-policy':'no-referrer','x-content-type-options':'nosniff'};
function fail(status,code,message){throw Object.assign(new Error(message),{status,code});}
const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:noStore});
const timestamp=()=>new Date().toISOString();
const scope=(p,s)=>{if(!p?.scopes.has(s))fail(403,'forbidden','This operation requires an authorized '+s+'.');};
function text(value,max=150){if(typeof value!=='string'||!value.trim()||value.length>max||/[\x00-\x1f]/.test(value))fail(422,'invalid_field','Invalid checkout field.');return value;}
function id(value){if(typeof value!=='string'||! /^[A-Za-z0-9._:-]{1,100}$/.test(value))fail(422,'invalid_id','Invalid identity.');return value;}
function date(value){if(value==null)return null;const time=Date.parse(value);if(!Number.isFinite(time)||time>Date.now()+300000)fail(422,'invalid_date','Invalid recorded time.');return new Date(time).toISOString();}
async function jsonBody(request,max=64*1024){
    if(!request.headers.get('content-type')?.startsWith('application/json'))fail(415,'json_required','JSON required.');
    const reader=request.body?.getReader();if(!reader)fail(400,'body_required','Request body required.');
    let size=0,parts=[];while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>max){await reader.cancel();fail(413,'payload_too_large','Upload exceeds the permitted size.');}parts.push(value);}
    const bytes=new Uint8Array(size);let o=0;for(const p of parts){bytes.set(p,o);o+=p.length;}
    try{return JSON.parse(new TextDecoder().decode(bytes));}catch{fail(400,'invalid_json','Invalid JSON.');}
}
export async function digest(value){return [...new Uint8Array(await crypto.subtle.digest('SHA-256',typeof value==='string'?encoder.encode(value):value))].map(b=>b.toString(16).padStart(2,'0')).join('');}
export async function mac(secret,value){const k=await crypto.subtle.importKey('raw',encoder.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);return [...new Uint8Array(await crypto.subtle.sign('HMAC',k,encoder.encode(value)))].map(b=>b.toString(16).padStart(2,'0')).join('');}
function equal(a,b){if(typeof a!=='string'||typeof b!=='string'||a.length!==b.length)return false;let d=0;for(let i=0;i<a.length;i++)d|=a.charCodeAt(i)^b.charCodeAt(i);return d===0;}
function enabled(env){if(env.MANUAL_CHECKOUT_ENABLED!=='true')fail(503,'manual_checkout_disabled','Mobile checkout is not enabled on this service. Local acknowledgment remains available when allowed.');}
async function incrementWindow(env, key, minute) {
    return env.DB.prepare(`INSERT INTO request_rate_limits(key,minute_window,request_count) VALUES(?,?,1)
      ON CONFLICT(key,minute_window) DO UPDATE SET request_count=request_count+1 RETURNING request_count`)
        .bind(key,minute).first();
}
async function rate(env,key,limit) {
    const row = await incrementWindow(env,key,Math.floor(Date.now()/60000));
    if(row.request_count > limit) fail(429,'rate_limited','Please wait a minute before retrying.');
}
function receiptEndpoint(env) {
    if (!env.RECEIPTS_SCRIPT_URL || env.RECEIPTS_HMAC_SECRET?.length < 32 || !env.RECEIPTS_HMAC_SECRET) return null;
    try {
        const url = new URL(env.RECEIPTS_SCRIPT_URL);
        return url.protocol === 'https:' && url.hostname === 'script.google.com' &&
            !url.username && !url.password && !url.port && !url.search && !url.hash &&
            /^\/macros\/s\/[A-Za-z0-9_-]+\/exec$/.test(url.pathname) ? url : null;
    } catch { return null; }
}
export function manualCheckoutHealth(env) {
    const enabled = env.MANUAL_CHECKOUT_ENABLED === 'true';
    return {enabled, checkoutReady: enabled && env.MANUAL_TOKEN_SECRET?.length >= 32 || false,
        receiptConfigured: enabled && receiptEndpoint(env) !== null};
}
export async function manualReceiptIncident(env) {
    const window = Math.floor(Date.now()/60000);
    const row = await env.DB.prepare(`SELECT COALESCE(SUM(request_count),0) AS failures FROM request_rate_limits
        WHERE key=? AND minute_window BETWEEN ? AND ?`).bind('manual-receipt-service-failures',window-14,window).first();
    return row.failures >= 3;
}
async function tokenFor(env,row){if(!env.MANUAL_TOKEN_SECRET||env.MANUAL_TOKEN_SECRET.length<32)fail(503,'manual_token_unconfigured','Checkout security is not configured.');return mac(env.MANUAL_TOKEN_SECRET,['manual-v1',row.environment,row.id,row.capability_nonce].join('\n'));}
async function owned(env,p,checkoutId,operator=false){const row=await env.DB.prepare('SELECT * FROM manual_checkouts WHERE id=? AND account_id=?'+(operator?'':' AND device_id=?')).bind(checkoutId,p.accountId,...(operator?[]:[p.id])).first();if(!row)fail(404,'checkout_not_found','Original checkout not found.');return row;}
async function receiptProof(env,row){const receipt=await env.DB.prepare("SELECT id,stored_at,trashed_at FROM manual_receipts WHERE checkout_id=? AND state='STORED_PRIVATE' ORDER BY stored_at DESC,id DESC LIMIT 1").bind(row.id).first();return receipt?{checkoutId:row.id,snapshotHash:row.snapshot_hash,receiptId:receipt.id,storedAt:receipt.stored_at,trashedAt:receipt.trashed_at}:null;}
async function status(env,row,origin,booth=false){const snapshot=JSON.parse(row.snapshot_json),receipt=await receiptProof(env,row);return {id:row.id,localCheckoutId:row.local_id,sessionId:row.session_id,snapshotHash:row.snapshot_hash,copies:snapshot.copies,totalCentavos:snapshot.copies*snapshot.unitPriceCentavos,acknowledgedAt:row.acknowledged_at,receipt,closedAt:row.closed_at,expiresAt:row.expires_at,receiptExpiresAt:row.receipt_expires_at,
    ...(booth?{checkoutURL:origin+'/checkout#c='+row.id+'.'+await tokenFor(env,row)}:{receiver:row.receiving_json?JSON.parse(row.receiving_json):null,method:snapshot.method,receiptPolicy:snapshot.receiptPolicy,receipt:receipt?{submitted:true}:null})};}
async function guest(request,env){
    enabled(env);const auth=request.headers.get('authorization')||'',match=auth.match(/^Checkout ([a-f0-9-]{36})\.([a-f0-9]{64})$/);
    const address=request.headers.get('cf-connecting-ip')||'unknown';await rate(env,'manual-address:'+await digest(address),120);
    if(!match)fail(401,'invalid_checkout_token','Scan the original checkout QR again.');
    const row=await env.DB.prepare('SELECT * FROM manual_checkouts WHERE id=?').bind(match[1]).first();
    if(!row||!equal(await digest(match[2]),row.capability_hash))fail(401,'invalid_checkout_token','Scan the original checkout QR again.');
    if(row.environment!==(env.PAYMENTS_ENVIRONMENT||'test'))fail(403,'environment_mismatch','Checkout environment mismatch.');
    if(Date.now()>Date.parse(row.receipt_expires_at))fail(410,'checkout_expired','This link has expired. Ask the attendant to review your original claim; do not pay again.');
    const origin=request.headers.get('origin');if(origin&&origin!==new URL(request.url).origin)fail(403,'origin_rejected','Open the original checkout page.');
    const statusRead = new URL(request.url).pathname === '/v2/guest/status';
    await rate(env,'manual-checkout:'+(statusRead?'status:':'write:')+row.id,statusRead?60:12);
    return row;
}

export async function manualPublic(request,env){
    const url=new URL(request.url),path=url.pathname;
    if(path==='/checkout'&&request.method==='GET')return new Response(mobileCheckoutPage(),{headers:{'content-type':'text/html; charset=utf-8','cache-control':'no-store','referrer-policy':'no-referrer','x-content-type-options':'nosniff','x-frame-options':'DENY','content-security-policy':"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"}});
    const row=await guest(request,env);
    if(request.method!=='POST')fail(405,'method_not_allowed','Use POST.');
    if(path==='/v2/guest/status')return reply(await status(env,row,url.origin));
    if(path==='/v2/guest/acknowledgments'){
        const body=await jsonBody(request);if(body.snapshotHash!==row.snapshot_hash)fail(409,'snapshot_mismatch','The amount or checkout changed. Ask the attendant.');
        const at=timestamp();
        // Decide acknowledgment versus late claim in the same SQL write as the closure check.
        // A booth close racing a mobile submission must retain the original claim either way.
        await env.DB.prepare(`UPDATE manual_checkouts SET
          acknowledged_at=CASE WHEN closed_at IS NULL AND expires_at>=? THEN COALESCE(acknowledged_at,?) ELSE acknowledged_at END,
          late_acknowledged_at=CASE WHEN closed_at IS NOT NULL OR expires_at<? THEN COALESCE(late_acknowledged_at,?) ELSE late_acknowledged_at END
          WHERE id=?`).bind(at,at,at,at,row.id).run();
        const current=await env.DB.prepare('SELECT * FROM manual_checkouts WHERE id=?').bind(row.id).first();
        if(current.closed_at||Date.now()>Date.parse(current.expires_at))fail(409,'claim_retained_for_review','Your claim is retained for the attendant. This checkout is closed; do not pay again.');
        return reply(await status(env,current,url.origin));
    }
    if(path==='/v2/guest/receipts')return storeReceipt(request,env,row);
    fail(404,'not_found','Unknown checkout operation.');
}

export async function manualAuthenticated(request,env,p){
    const url=new URL(request.url),path=url.pathname;enabled(env);
    const isAdmin=path.startsWith('/v2/admin/');scope(p,isAdmin?'operator':'booth');
    if(path==='/v2/admin/receiving-accounts'&&request.method==='POST'){
        const b=await jsonBody(request,400*1024);id(b.id);text(b.provider,100);text(b.recipient);text(b.identifier);text(b.instructions,1000);
        if(b.permittedUseConfirmed!==true)fail(422,'receiving_permission_required','Confirm this receiving account is permitted for the intended activity.');
        if(b.qrJPEG){let bytes;try{bytes=Uint8Array.from(atob(b.qrJPEG),c=>c.charCodeAt(0));}catch{fail(422,'invalid_receiving_qr','Invalid receiving QR image.');}if(bytes.length>262144)fail(413,'receiving_qr_too_large','Receiving QR image is too large.');normalizeReceipt(bytes,'image/jpeg');}
        const config=JSON.stringify({id:b.id,provider:b.provider,recipient:b.recipient,identifier:b.identifier,instructions:b.instructions,qrJPEG:b.qrJPEG||null});
        const old=await env.DB.prepare('SELECT * FROM manual_receivers WHERE id=?').bind(b.id).first();
        if(old&&(old.account_id!==p.accountId||old.configuration_json!==config))fail(409,'receiver_revision_conflict','Create a new receiving-account revision.');
        await env.DB.prepare('INSERT INTO manual_receivers(id,account_id,configuration_json,enabled,created_at) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled').bind(b.id,p.accountId,config,+!!b.enabled,timestamp()).run();return reply({accepted:true});
    }
    if(path==='/v2/admin/retention'&&request.method==='POST'){
        const b=await jsonBody(request);if(b.approved!==true||!Number.isInteger(b.days)||b.days<1||b.days>3650)fail(422,'retention_not_approved','Explicitly establish a reviewed retention period first.');
        await receiptStorage(env,'retention',crypto.randomUUID(),{days:b.days,approved:true});
        await env.DB.prepare('INSERT INTO manual_retention_policies(account_id,days,actor_device_id,established_at) VALUES(?,?,?,?) ON CONFLICT(account_id) DO UPDATE SET days=excluded.days,actor_device_id=excluded.actor_device_id,established_at=excluded.established_at').bind(p.accountId,b.days,p.id,timestamp()).run();
        return reply({accepted:true});
    }
    if(path==='/v2/booth/checkouts'&&request.method==='POST')return createCheckout(request,env,p,url.origin);
    const match=path.match(/^\/v2\/(booth|admin)\/checkouts\/([a-f0-9-]{36})(?:\/(facts|reviews))?$/);
    if(match){
        const row=await owned(env,p,match[2],isAdmin);
        if(request.method==='GET'&&!match[3])return reply(await status(env,row,url.origin,true));
        if(request.method==='POST'&&match[3]==='facts'&&!isAdmin){
            const b=await jsonBody(request);if(b.snapshotHash!==row.snapshot_hash)fail(409,'snapshot_mismatch','Original checkout snapshot mismatch.');
            if(b.printEvidence!==undefined){
                if(!Array.isArray(b.printEvidence)||b.printEvidence.length>100)fail(422,'invalid_print_evidence','Invalid original print evidence.');
                const copies = JSON.parse(row.snapshot_json).copies;
                const evidence = b.printEvidence.map(entry => {
                    id(entry.id); id(entry.batchID);
                    if (entry.sessionID !== row.session_id || !Number.isInteger(entry.copyIndex) ||
                        entry.copyIndex < 1 || entry.copyIndex > copies ||
                        !['inFlight','notStarted','delivered','uncertain'].includes(entry.localState)) {
                        fail(409,'print_evidence_mismatch','Print evidence must match the original session and frozen copies.');
                    }
                    const updatedAt = date(entry.updatedAt);
                    if (!updatedAt) fail(422,'invalid_date','Print evidence needs its original recorded time.');
                    return {id:entry.id,batchID:entry.batchID,sessionID:entry.sessionID,copyIndex:entry.copyIndex,
                        receiptFingerprint:text(entry.receiptFingerprint,128),localState:entry.localState,updatedAt};
                });
                if (new Set(evidence.map(entry=>entry.id)).size !== evidence.length) {
                    fail(422,'duplicate_print_evidence','Each physical evidence ID may appear once.');
                }
                if (evidence.length) {
                    const encoded = JSON.stringify(evidence);
                    const matchingIdentity = `json_extract(current.payload_json,'$.batchID')=json_extract(incoming.value,'$.batchID')
                        AND json_extract(current.payload_json,'$.copyIndex')=json_extract(incoming.value,'$.copyIndex')
                        AND json_extract(current.payload_json,'$.receiptFingerprint')=json_extract(incoming.value,'$.receiptFingerprint')
                        AND NOT (json_extract(current.payload_json,'$.localState') IN ('uncertain','delivered')
                                 AND json_extract(incoming.value,'$.localState') IN ('notStarted','inFlight'))`;
                    // One indexed batch for up to 100 entries, below the Free D1 query limit.
                    // An all-or-nothing conditional insert also protects against a racing update.
                    const conflict = `SELECT 1 FROM json_each(?1) incoming JOIN manual_print_evidence current
                        ON current.checkout_id=?2 AND current.id=json_extract(incoming.value,'$.id')
                        WHERE NOT (${matchingIdentity}) LIMIT 1`;
                    const [, check] = await env.DB.batch([
                        env.DB.prepare(`INSERT INTO manual_print_evidence(checkout_id,id,payload_json,updated_at)
                          SELECT ?2,json_extract(value,'$.id'),value,json_extract(value,'$.updatedAt')
                          FROM json_each(?1) WHERE NOT EXISTS (${conflict})
                          ON CONFLICT(checkout_id,id) DO UPDATE SET payload_json=excluded.payload_json,updated_at=excluded.updated_at
                          WHERE excluded.updated_at>=manual_print_evidence.updated_at`).bind(encoded,row.id),
                        env.DB.prepare(conflict).bind(encoded,row.id)
                    ]);
                    if (check.results.length) fail(409,'print_evidence_conflict','Original physical evidence cannot be replaced.');
                }
            }
            await env.DB.prepare('UPDATE manual_checkouts SET acknowledged_at=COALESCE(acknowledged_at,?),closed_at=COALESCE(closed_at,?),completed_at=COALESCE(completed_at,?) WHERE id=?').bind(date(b.acknowledgedAt),date(b.closedAt),date(b.completedAt),row.id).run();return reply(await status(env,await owned(env,p,row.id),url.origin,true));
        }
        if(request.method==='POST'&&match[3]==='reviews'&&isAdmin){
            const b=await jsonBody(request);id(b.id);text(b.note,1000);if(!['FUNDS_CONFIRMED','MISMATCH','NEEDS_REVIEW'].includes(b.outcome)||b.outcome==='FUNDS_CONFIRMED'&&(!Number.isSafeInteger(b.confirmedCentavos)||b.confirmedCentavos<0))fail(422,'invalid_review','Record the independently checked outcome and amount.');
            const hash=await digest(JSON.stringify([row.id,b.outcome,b.confirmedCentavos??null,b.note]));
            const prior=await env.DB.prepare('SELECT payload_hash FROM manual_reviews WHERE id=?').bind(b.id).first();if(prior&&prior.payload_hash!==hash)fail(409,'review_replay_mismatch','Review ID was reused.');
            await env.DB.prepare('INSERT OR IGNORE INTO manual_reviews(id,checkout_id,actor_device_id,outcome,confirmed_centavos,note,created_at,payload_hash) VALUES(?,?,?,?,?,?,?,?)').bind(b.id,row.id,p.id,b.outcome,b.confirmedCentavos??null,b.note,timestamp(),hash).run();return reply({accepted:true});
        }
    }
    if(path==='/v2/admin/records'&&request.method==='GET'){
        const rows=await env.DB.prepare(`SELECT c.id,c.local_id,c.session_id,c.snapshot_json,c.acknowledged_at,c.closed_at,c.completed_at,c.created_at,
          (SELECT outcome FROM manual_reviews WHERE checkout_id=c.id ORDER BY created_at DESC,id DESC LIMIT 1) verification,
          (SELECT confirmed_centavos FROM manual_reviews WHERE checkout_id=c.id ORDER BY created_at DESC,id DESC LIMIT 1) confirmed_centavos,
          (SELECT COUNT(*) FROM manual_receipts WHERE checkout_id=c.id AND state='STORED_PRIVATE') receipt_count,
          (SELECT COUNT(*) FROM manual_print_evidence WHERE checkout_id=c.id) print_evidence_count
          FROM manual_checkouts c WHERE c.account_id=? AND (c.created_at<? OR (c.created_at=? AND c.id<?)) ORDER BY c.created_at DESC,c.id DESC LIMIT 101`)
          .bind(p.accountId,url.searchParams.get('before')||'9999',url.searchParams.get('before')||'9999',url.searchParams.get('id')||'~').all();
        const page=rows.results.slice(0,100);return reply({records:page,next:rows.results.length>100?{before:page.at(-1).created_at,id:page.at(-1).id}:null});
    }
    const preview=path.match(/^\/v2\/admin\/receipts\/([a-f0-9-]{36})(?:\/(trash))?$/);
    if(preview&&(request.method==='GET'||request.method==='POST'&&preview[2]==='trash')){
        const receipt=await env.DB.prepare("SELECT r.* FROM manual_receipts r JOIN manual_checkouts c ON c.id=r.checkout_id WHERE r.id=? AND c.account_id=? AND r.state='STORED_PRIVATE'").bind(preview[1],p.accountId).first();
        if(!receipt)fail(404,'receipt_not_found','Private receipt not found.');
        const saved=JSON.parse(receipt.storage_json);
        if(preview[2]==='trash'){
            const b=await jsonBody(request);text(b.reason,1000);
            const policy=await env.DB.prepare('SELECT days FROM manual_retention_policies WHERE account_id=?').bind(p.accountId).first();
            if(b.approved!==true||!policy||Date.now()-Date.parse(receipt.stored_at)<policy.days*86400000)fail(409,'retention_not_approved','This receipt is not eligible under the established retention policy.');
            await env.DB.prepare('INSERT OR IGNORE INTO manual_receipt_trash_audit(receipt_id,actor_device_id,reason,retention_days,created_at) VALUES(?,?,?,?,?)').bind(receipt.id,p.id,b.reason,policy.days,timestamp()).run();
            const result=await receiptStorage(env,'trash',receipt.id,{fileId:saved.fileId,retentionApproved:true});
            if(result.trashed!==true)fail(503,'trash_unconfirmed','Trash operation is unconfirmed. Retry the same receipt.');
            await env.DB.prepare('UPDATE manual_receipts SET trashed_at=COALESCE(trashed_at,?) WHERE id=?').bind(timestamp(),receipt.id).run();return reply({accepted:true});
        }
        if(receipt.trashed_at)fail(410,'receipt_trashed','Receipt was moved to recoverable Drive Trash under the retention policy. The original payment association is retained.');
        const result=await receiptStorage(env,'read',receipt.id,{fileId:saved.fileId,sha256:receipt.content_hash});return reply({mimeType:receipt.mime_type,base64:result.base64,folderURL:saved.folderURL});
    }
    fail(404,'not_found','Unknown payment operation.');
}

async function createCheckout(request,env,p,origin){
    const b=await jsonBody(request);id(b.localCheckoutId);id(b.sessionId);id(b.eventId||'regular');if(b.runId)id(b.runId);
    if(!formats.has(b.format)||!Number.isInteger(b.copies)||b.copies<1||b.copies>10||!Number.isSafeInteger(b.unitPriceCentavos)||b.unitPriceCentavos<1||b.unitPriceCentavos>10_000_000||!['CASH','MANUAL_DIGITAL'].includes(b.method)||!['ACK_ONLY','OPTIONAL','REQUIRED'].includes(b.receiptPolicy))fail(422,'invalid_checkout','Invalid checkout snapshot.');
    if(!['cash','digital','cashAndDigital'].includes(b.mode)||(b.method==='CASH'&&b.mode==='digital')||(b.method==='MANUAL_DIGITAL'&&b.mode==='cash'))fail(422,'method_not_allowed','Payment method is outside the frozen mode.');
    const snapshot={localCheckoutId:b.localCheckoutId,sessionId:b.sessionId,eventId:b.eventId||'',eventName:String(b.eventName||'Regular Booth').slice(0,150),runId:b.runId||null,format:b.format,copies:b.copies,unitPriceCentavos:b.unitPriceCentavos,method:b.method,receiptPolicy:b.receiptPolicy,receiverId:b.receiverId||null,mode:b.mode};
    const hash=await digest([b.localCheckoutId,b.sessionId,b.eventId||'',b.runId||'',b.format,String(b.copies),String(b.unitPriceCentavos),b.method,b.receiptPolicy,b.receiverId||'',b.mode].join('\n'));
    if(hash!==b.snapshotHash)fail(409,'snapshot_mismatch','Checkout snapshot hash mismatch.');
    const existing=await env.DB.prepare('SELECT * FROM manual_checkouts WHERE device_id=? AND (local_id=? OR session_id=?)').bind(p.id,b.localCheckoutId,b.sessionId).first();
    if(existing){if(existing.snapshot_hash!==hash)fail(409,'checkout_replay_mismatch','This session already has a different frozen checkout.');return reply(await status(env,existing,origin,true));}
    let receiver=null;
    if(b.method==='MANUAL_DIGITAL'){
        receiver=await env.DB.prepare('SELECT configuration_json FROM manual_receivers WHERE id=? AND account_id=? AND enabled=1').bind(b.receiverId||'',p.accountId).first();
        if(!receiver)fail(409,'receiving_account_unconfigured','Configure an authorized receiving account first.');
        if(b.receiptPolicy==='REQUIRED'&&!receiptEndpoint(env))fail(503,'receipt_storage_unavailable','Private receipt storage is unavailable. Local required-receipt policy remains enforced.');
    }
    const originalCreatedAt=date(b.createdAt)||timestamp();
    const now=timestamp(),originTime=Date.parse(originalCreatedAt),row={id:crypto.randomUUID(),environment:env.PAYMENTS_ENVIRONMENT||'test',capability_nonce:crypto.randomUUID()+crypto.randomUUID()};
    const token=await tokenFor(env,row);
    await env.DB.prepare(`INSERT OR IGNORE INTO manual_checkouts(id,local_id,device_id,account_id,environment,session_id,snapshot_hash,snapshot_json,receiving_json,capability_nonce,capability_hash,created_at,expires_at,receipt_expires_at)
       VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(row.id,b.localCheckoutId,p.id,p.accountId,row.environment,b.sessionId,hash,JSON.stringify(snapshot),receiver?.configuration_json||null,row.capability_nonce,await digest(token),now,new Date(Math.min(Date.now(),originTime)+30*60000).toISOString(),new Date(Math.min(Date.now(),originTime)+24*3600000).toISOString()).run();
    const stored=await env.DB.prepare('SELECT * FROM manual_checkouts WHERE device_id=? AND local_id=?').bind(p.id,b.localCheckoutId).first();
    if(!stored||stored.snapshot_hash!==hash)fail(409,'checkout_replay_mismatch','Checkout already exists for this guest.');return reply(await status(env,stored,origin,true),201);
}

async function storeReceipt(request,env,row){
    const snapshot=JSON.parse(row.snapshot_json);if(snapshot.method!=='MANUAL_DIGITAL')fail(409,'digital_receipt_only','This checkout does not accept digital receipts.');
    const b=await jsonBody(request,3*1024*1024);if(b.snapshotHash!==row.snapshot_hash)fail(409,'snapshot_mismatch','Receipt belongs to a different checkout.');
    let bytes;try{if(typeof b.base64!=='string'||b.base64.length>Math.ceil(RECEIPT_MAX_BYTES*4/3)+4)throw Error();bytes=Uint8Array.from(atob(b.base64),c=>c.charCodeAt(0));}catch{fail(422,'invalid_receipt_image','Choose a JPEG or PNG under 2 MiB.');}
    const image=normalizeReceipt(bytes,b.mimeType),hash=await digest(image.bytes),requestHash=hash;
    let receipt=await env.DB.prepare('SELECT * FROM manual_receipts WHERE checkout_id=? AND request_hash=?').bind(row.id,requestHash).first();
    if(receipt?.state==='STORED_PRIVATE')return reply({submitted:true,receiptId:receipt.id});
    const count=await env.DB.prepare('SELECT COUNT(*) count FROM manual_receipts WHERE checkout_id=?').bind(row.id).first();if(!receipt&&count.count>=3)fail(429,'receipt_limit','Three receipt versions are already retained. Ask the attendant.');
    const receiptId=receipt?.id||crypto.randomUUID();
    await env.DB.prepare("INSERT OR IGNORE INTO manual_receipts(id,checkout_id,request_hash,content_hash,mime_type,bytes,state,created_at) SELECT ?,?,?,?,?,?,'RESERVED',? WHERE (SELECT COUNT(*) FROM manual_receipts WHERE checkout_id=?)<3").bind(receiptId,row.id,requestHash,hash,image.mime,image.bytes.length,timestamp(),row.id).run();
    receipt=await env.DB.prepare('SELECT * FROM manual_receipts WHERE checkout_id=? AND request_hash=?').bind(row.id,requestHash).first();
    if(!receipt)fail(429,'receipt_limit','Three receipt versions are already retained. Ask the attendant.');
    const encoded=base64(image.bytes);
    let stored;
    try {
        stored=await receiptStorage(env,'store',receipt.id,{checkoutId:row.id,eventId:snapshot.eventId,runId:snapshot.runId,year:row.created_at.slice(0,4),month:row.created_at.slice(5,7),date:row.created_at.slice(0,10),sha256:hash,mimeType:image.mime,bytes:image.bytes.length,base64:encoded});
        if(stored.private!==true||stored.sha256!==hash||stored.bytes!==image.bytes.length||!/^[A-Za-z0-9_-]{10,200}$/.test(stored.fileId||'')||!/^https:\/\/drive\.google\.com\/drive\/folders\/[A-Za-z0-9_-]{10,200}$/.test(stored.folderURL||''))fail(502,'receipt_storage_unverified','Private storage could not be verified. Retry the same image; do not pay again.');
    } catch (error) {
        // A fixed index key and minute bucket contain no payment or guest details.
        try { await incrementWindow(env,'manual-receipt-service-failures',Math.floor(Date.now()/60000)); } catch { /* preserve the original storage response */ }
        throw error;
    }
    await env.DB.prepare("UPDATE manual_receipts SET state='STORED_PRIVATE',storage_json=?,stored_at=COALESCE(stored_at,?) WHERE id=? AND content_hash=?").bind(JSON.stringify({fileId:stored.fileId,folderURL:stored.folderURL}),timestamp(),receipt.id,hash).run();return reply({submitted:true,receiptId:receipt.id});
}
function base64(bytes){let result='';for(let i=0;i<bytes.length;i+=16384)result+=String.fromCharCode(...bytes.subarray(i,i+16384));return btoa(result);}
export async function receiptStorage(env,operation,operationId,payload){
    const url = receiptEndpoint(env);
    if (!url) fail(503,'receipt_storage_unavailable','Private Drive receipt storage is unavailable.');
    const keyId = env.RECEIPTS_KEY_ID === 'receipt-live-v1' ? 'receipt-live-v1' : 'receipt-v1';
    const envelope={v:1,keyId,timestamp:timestamp(),nonce:crypto.randomUUID(),operationId,operation,payloadB64:base64(encoder.encode(JSON.stringify(payload)))};
    envelope.signature=await mac(env.RECEIPTS_HMAC_SECRET,['v1',envelope.keyId,envelope.timestamp,envelope.nonce,operationId,operation,envelope.payloadB64].join('\n'));
    let response;try{response=await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(envelope),redirect:'manual',signal:AbortSignal.timeout(45000)});
        for(let redirects=0;[301,302,303].includes(response.status)&&redirects<3;redirects++){
            const next=new URL(response.headers.get('location'));if(next.protocol!=='https:'||!['script.googleusercontent.com','script.google.com'].includes(next.hostname))throw Error('redirect');
            response=await fetch(next,{redirect:'manual',signal:AbortSignal.timeout(45000)});
        }
        const body=await response.json();if(!response.ok||body.operationId!==operationId||body.operation!==operation||!equal(body.signature,await mac(env.RECEIPTS_HMAC_SECRET,operationId+'\n'+operation+'\n'+body.payloadB64)))throw Error('unverified');
        const result=JSON.parse(atob(body.payloadB64));if(result.ok!==true)throw Error('storage');return result;
    }catch{fail(503,'receipt_storage_pending','Storage confirmation is unavailable. Retry the same receipt; the original operation is retained.');}
}
