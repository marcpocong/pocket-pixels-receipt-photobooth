import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, readdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const require=createRequire(new URL('../../PaymentsWorker/package.json',import.meta.url));
const {Miniflare,convertV4MiniflareOptions}=require('miniflare');
const device='d'.repeat(48),owner='o'.repeat(48),webhook='w'.repeat(48);
const ownerChat=424242;
const clean={mode:'regular',network:'online',payment:'ready',printer:'ready',storage:'ready',incidents:[]};

async function withMonitor(body, paymentsHealth=false, options={}) {
    const messages=[],healthCalls=[];let heldResponse=null;let failTelegram=false,telegramRetryAfter=null,healthStatus=200,health={environment:'live',liveEnabled:true,reconciliationFresh:true};
    const persist=options.persist?mkdtempSync(join(tmpdir(),'mtk-monitor-v3-')):null;
    const workerOptions={...(persist?{resourcePersistencePath:persist}:{}),modules:true,script:readFileSync(new URL('../src/index.js',import.meta.url),'utf8'),compatibilityDate:'2026-10-01',d1Databases:['DB'],bindings:{DEVICE_TOKEN:device,OWNER_READ_TOKEN:owner,TELEGRAM_BOT_TOKEN:'test-only',TELEGRAM_CHAT_ID:String(ownerChat),TELEGRAM_WEBHOOK_SECRET:webhook,STALE_SECONDS:'900',...(paymentsHealth?{PAYMENTS_HEALTH_URL:'https://payments.test/v1/monitor-health',PAYMENTS_HEALTH_TOKEN:'health-read-only'}:{})},outboundService:async request=>{
        if(new URL(request.url).hostname==='payments.test') {
            healthCalls.push({authorization:request.headers.get('authorization')});
            return Response.json(health,{status:healthStatus});
        }
        messages.push(await request.json());const gate=heldResponse;if(gate){heldResponse=null;gate.signal();await gate.wait;}if(telegramRetryAfter!=null) return Response.json({ok:false,parameters:{retry_after:telegramRetryAfter}},{status:429});return Response.json({ok:!failTelegram},{status:failTelegram?503:200});
    }};
    if(options.budget || options.leaseTakeover) workerOptions.script=budgetScript(workerOptions.script,!!options.leaseTakeover);
    const config=convertV4MiniflareOptions(workerOptions);
    let mf=new Miniflare(config);
    try {
        let db=await mf.getD1Database('DB');
        for(const migration of readdirSync(new URL('../migrations/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort()) {
            if(migration.startsWith('0004') && options.beforeV3) await options.beforeV3(db);
            for (const statement of readFileSync(new URL('../migrations/'+migration,import.meta.url),'utf8').replace(/^--.*$/gm,'').split(';').map(s=>s.trim()).filter(Boolean)) await db.prepare(statement).run();
        }
        const h={holdNextTelegram(){let signal,release;const started=new Promise(r=>signal=r),wait=new Promise(r=>release=r);heldResponse={signal,wait};return{started,release};},get db(){return db;},async restart(v2=false){await mf.dispose();mf=new Miniflare(convertV4MiniflareOptions({...workerOptions,script:v2?readFileSync(new URL('./fixtures/monitoring-v2.js',import.meta.url),'utf8'):workerOptions.script}));db=await mf.getD1Database('DB');},messages,healthCalls,set fail(value){failTelegram=value;},set telegramRetryAfter(value){telegramRetryAfter=value;},set healthStatus(value){healthStatus=value;},set health(value){health=value;},async request(path,body,token=device){return mf.dispatchFetch('https://monitor.test'+path,{method:body?'POST':'GET',headers:{authorization:'Bearer '+token,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});},async telegram(body,secret=webhook) {return mf.dispatchFetch('https://monitor.test/v1/telegram',{method:'POST',headers:{'x-telegram-bot-api-secret-token':secret,'content-type':'application/json'},body:typeof body==='string'?body:JSON.stringify(body)});},async tick(time=Date.now()){
            await (await mf.getWorker()).scheduled({cron:'*/5 * * * *',scheduledTime:new Date(time)});
            // Concurrent heartbeat/Cron deliveries hold real leases until outbound work finishes.
            for(let i=0;i<200;i++) {
                const leases=await db.prepare(`SELECT (SELECT COUNT(*) FROM notifications WHERE lease_until IS NOT NULL)+(SELECT COUNT(*) FROM telegram_commands WHERE lease_until IS NOT NULL)+(SELECT COUNT(*) FROM v3_notifications WHERE lease_until IS NOT NULL)+(SELECT COUNT(*) FROM monitoring_locks WHERE id LIKE 'delivery:%' AND expires_at>?) c`).bind(Date.now()).first();
                if(!leases.c) return;
                await new Promise(resolve=>setTimeout(resolve,10));
            }
            assert.fail('monitoring delivery did not settle');
        }};
        await body(h);
    } finally {await mf.dispose();if(persist)rmSync(persist,{recursive:true,force:true});}
}

test('heartbeat and owner read-only overview authenticate with different scopes',()=>withMonitor(async h=>{
    assert.equal((await h.request('/v1/heartbeat',clean,'bad')).status,401);
    assert.equal((await h.request('/v1/heartbeat',clean)).status,200);
    assert.equal((await h.request('/v1/overview',null,device)).status,401);
    const overview=await (await h.request('/v1/overview',null,owner)).json();
    assert.equal(overview.online,true);assert.equal(overview.state.mode,'regular');
    assert.equal((await h.request('/v1/heartbeat',clean)).status,429);
}));

test('unknown sensitive fields and arbitrary incident text are rejected',()=>withMonitor(async h=>{
    for(const bad of [{...clean,photo:'secret'},{...clean,incidents:['token=private']},{...clean,eventReference:'https://gallery/token'}]) {
        assert.equal((await h.request('/v1/heartbeat',bad)).status,422);
    }
    assert.equal((await h.db.prepare('SELECT COUNT(*) c FROM devices').first()).c,0);
}));

test('missing heartbeat raises one offline incident and duplicate scheduled checks do not flood',()=>withMonitor(async h=>{
    await h.request('/v1/heartbeat',clean);
    await h.tick();
    await h.db.prepare('UPDATE devices SET last_seen=?').bind(Date.now()-20*60_000).run();
    await h.tick();await h.tick();
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='offline'").first()).active,1);
    assert.equal(h.messages.length,1);
    assert.ok(h.messages[0].text.includes('heartbeat missing'));
    await h.request('/v1/heartbeat',clean);
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='offline'").first()).active,0);
    const pending=await h.db.prepare("SELECT COUNT(*) c FROM notifications WHERE code='offline'").first();
    assert.equal(pending.c,2,'one incident and one recovery');
}));

test('printer alerts are deduplicated and contain only fixed health text',()=>withMonitor(async h=>{
    const state={...clean,printer:'uncertain',incidents:['uncertain_print']};
    await h.request('/v1/heartbeat',state);await h.tick();
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    await h.request('/v1/heartbeat',state);await h.tick();
    assert.equal(h.messages.length,1);
    assert.ok(h.messages[0].text.includes('Physical print outcome uncertain'));
    assert.ok(!JSON.stringify(h.messages).includes(device));
}));

test('Telegram outage retries are bounded and failed incidents remain visible',()=>withMonitor(async h=>{
    h.fail=true;
    await h.request('/v1/heartbeat',{...clean,storage:'error',incidents:['storage']});
    for(let i=0;i<8;i++) {
        await h.db.prepare('UPDATE notifications SET next_at=0,lease_until=NULL').run();
        await h.tick();
    }
    assert.equal((await h.db.prepare("SELECT attempts FROM notifications WHERE code='storage'").first()).attempts,5);
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='storage'").first()).active,1);
    assert.equal(h.messages.length,5);
}));

test('recovered incidents after Telegram failure cannot block delivery of newer alerts',()=>withMonitor(async h=>{
    h.fail=true;
    await h.request('/v1/heartbeat',{...clean,incidents:['storage','printer','review']});
    await h.tick();
    assert.equal(h.messages.length,3);
    h.fail=false;h.messages.length=0;
    await h.db.prepare('UPDATE notifications SET next_at=0,lease_until=NULL').run();
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    await h.request('/v1/heartbeat',clean);
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    await h.request('/v1/heartbeat',{...clean,printer:'uncertain',incidents:['uncertain_print']});
    await h.tick();
    assert.equal(h.messages.filter(m=>m.text.includes('Physical print outcome uncertain')).length,1);
    const obsolete=await h.db.prepare("SELECT attempts,delivered_at,superseded_at FROM notifications WHERE code='storage' AND active=1").first();
    assert.equal(obsolete.attempts,1);
    assert.equal(obsolete.delivered_at,null,'superseded must not be reported as sent');
    assert.ok(obsolete.superseded_at);
}));

test('payment backend failures are authenticated, deduplicated and recover promptly',()=>withMonitor(async h=>{
    h.healthStatus=503;
    await h.tick();await h.tick();
    assert.equal(h.messages.length,1);
    assert.ok(h.messages[0].text.includes('Payment backend unavailable'));
    assert.equal(h.healthCalls[0].authorization,'Bearer health-read-only');
    h.healthStatus=200;
    await h.tick();
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='backend'").first()).active,0);
    assert.equal(h.messages.length,2,'evidence-backed recovery bypasses the old cooldown');
    await h.tick(Date.now()+16*60_000);
    assert.equal(h.messages.length,2,'repeated health checks do not duplicate recovery');
    assert.ok(h.messages[1].text.includes('RECOVERED'));
},true));

test('wrong payment environment or disabled LIVE gate raises a backend incident',async()=>{
    for(const health of [{environment:'test',liveEnabled:true,reconciliationFresh:true},{environment:'live',liveEnabled:false,reconciliationFresh:true}]) {
        await withMonitor(async h=>{
            h.health=health;await h.tick();
            assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='backend'").first()).active,1);
            assert.equal(h.messages.length,1);
        },true);
    }
});

test('stale reconciliation raises its own incident without claiming a backend outage',()=>withMonitor(async h=>{
    h.health={environment:'live',liveEnabled:true,reconciliationFresh:false};
    await h.tick();await h.tick();
    assert.equal(h.messages.length,1);
    assert.ok(h.messages[0].text.includes('Backend reconciliation stale'));
    assert.equal(await h.db.prepare("SELECT active FROM incidents WHERE code='backend'").first(),null);
    h.health={environment:'live',liveEnabled:true,reconciliationFresh:true};
    await h.tick();
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='reconciliation'").first()).active,0);
},true));

function update(id,text='/status',changes={}) {
    return {update_id:id,message:{date:Math.floor(Date.now()/1000),chat:{id:ownerChat,type:'private'},from:{id:ownerChat,is_bot:false},text,...changes}};
}
const queue={pending:3,uploading:0,verifying:1,attention:1,oldestAt:new Date(Date.now()-1200000).toISOString(),activityAt:new Date().toISOString()};

test('owner commands report last-known telemetry and independent backend health',()=>withMonitor(async h=>{
    await h.request('/v1/heartbeat',{...clean,eventReference:'evt-synthetic',reportedAt:new Date().toISOString(),eventState:'active',uploads:queue});
    await h.tick();
    for(const [id,command] of ['/status','/event','/uploads','/incidents','/help'].entries()) {
        assert.equal((await h.telegram(update(id,command))).status,200);await h.tick();
    }
    const text=h.messages.map(m=>m.text).join('\n');
    for(const value of ['Fresh at report time','Network path: online','Payment backend: available','evt-synthetic','Last reported unverified queue: 3','Verifying: 1','Needs attention: 1','WARNING','read only']) assert.ok(text.includes(value),value);
    for(const secret of [device,owner,webhook,'test-only','galleryToken','paymentId']) assert.ok(!text.includes(secret),secret);
    assert.equal((await h.db.prepare('SELECT COUNT(*) c FROM telegram_commands').first()).c,5);
    assert.ok(h.messages.every(m=>String(m.chat_id)===String(ownerChat) && m.protect_content));
},true));

test('webhook secret and private owner identity fail closed before persistence',()=>withMonitor(async h=>{
    for(const secret of ['', 'invalid']) assert.equal((await h.telegram(update(1),secret)).status,401);
    for(const changes of [{forward_from_chat:{id:ownerChat}},{forward_sender_name:'forwarded'},{forward_date:1},{is_automatic_forward:true},{chat:{id:99,type:'private'}},{chat:{id:ownerChat,type:'group'}},{from:{id:99,is_bot:false}},{from:{id:ownerChat,is_bot:true}},{forward_origin:{type:'user'}},{sender_chat:{id:ownerChat}}]) {
        assert.equal((await h.telegram(update(1,'/status',changes))).status,403);
    }
    assert.equal((await h.db.prepare('SELECT COUNT(*) c FROM telegram_commands').first()).c,0);
    assert.equal(h.messages.length,0);
}));

test('malformed and oversized bodies, old updates and arbitrary commands cannot execute',()=>withMonitor(async h=>{
    assert.equal((await h.telegram('{')).status,422);
    assert.equal((await h.telegram('x'.repeat(4097))).status,413);
    for(const body of [update(-1),{...update(1),update_id:1.1},update(1,'/status',{date:0}),update(1,'x'.repeat(129)),null]) {
        assert.ok([403,422].includes((await h.telegram(body)).status));
    }
    for(const command of ['/print','/delete','/event secret','/status;print','arbitrary text','/payment','/status\n/print']) {
        assert.equal((await h.telegram(update(1,command))).status,200);
    }
    assert.equal((await h.db.prepare('SELECT COUNT(*) c FROM telegram_commands').first()).c,0);
    assert.equal((await h.db.prepare('SELECT COUNT(*) c FROM devices').first()).c,0);
    assert.equal(h.messages.length,0);
}));

test('concurrent replay creates one reply and command rate limiting is atomic',()=>withMonitor(async h=>{
    const replies=await Promise.all(Array.from({length:8},()=>h.telegram(update(100,'/uploads'))));
    assert.ok(replies.every(r=>r.status===200));await h.tick();
    assert.equal((await h.db.prepare('SELECT COUNT(*) c FROM telegram_commands').first()).c,1);
    assert.equal(h.messages.length,1);
    await h.db.prepare('DELETE FROM telegram_rate').run();
    const limited=await Promise.all(Array.from({length:20},(_,i)=>h.telegram(update(200+i,'/help'))));
    assert.equal(limited.filter(r=>r.status===200).length,10);
    assert.equal(limited.filter(r=>r.status===429).length,10);
    assert.equal((await h.db.prepare('SELECT COUNT(*) c FROM telegram_commands').first()).c,11);
    assert.equal((await h.telegram(update(100,'/uploads'))).status,200);
}));

test('stale and old telemetry never pretends metrics or equipment are live',()=>withMonitor(async h=>{
    await h.request('/v1/heartbeat',clean);
    await h.db.prepare('UPDATE devices SET last_seen=?').bind(Date.now()-20*60000).run();
    assert.equal((await h.telegram(update(1,'/uploads'))).status,200);await h.tick();
    const reply=h.messages.find(m=>m.text.includes('Upload metrics not reported'));
    assert.ok(reply.text.includes('STALE / unavailable'));
    await h.request('/v1/heartbeat',{...clean,eventState:'paused',uploads:queue});
    await h.db.prepare('UPDATE devices SET last_seen=?').bind(Date.now()-20*60000).run();
    await h.telegram(update(2,'/uploads'));await h.tick();
    const stale=h.messages.find(m=>m.text.includes('Last reported unverified queue: 3'));
    assert.ok(stale.text.includes('STALE / unavailable'));
    assert.ok(!stale.text.includes('Available Online'));
}));

test('idle offline backlog is quiet; active delayed delivery warns and recovers',()=>withMonitor(async h=>{
    const old={...queue,attention:0,verifying:0};
    await h.request('/v1/heartbeat',{...clean,network:'offline',eventState:'idle',uploads:old});await h.tick();
    assert.equal(h.messages.length,0);
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    await h.request('/v1/heartbeat',{...clean,eventState:'active',uploads:old});await h.tick();
    assert.equal(h.messages.length,1);assert.ok(h.messages[0].text.includes('WARNING'));
    assert.ok(h.messages[0].text.includes('Waiting Galleries'));
    assert.ok(h.messages[0].text.includes('pending public verification'));
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    await h.request('/v1/heartbeat',{...clean,eventState:'active',uploads:{pending:0,uploading:0,verifying:0,attention:0}});await h.tick(Date.now()+16*60000);
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='uploads'").first()).active,0);
    assert.ok(h.messages.some(m=>m.text.includes('RECOVERED: Gallery delivery')));
}));

test('bounded telemetry rejects invalid counts, dates, unknown fields and guest details',()=>withMonitor(async h=>{
    for(const changes of [{pending:-1},{pending:1e8},{uploading:1,verifying:1},{attention:4},{token:'secret'},{oldestAt:'not-a-date'}]) {
        assert.equal((await h.request('/v1/heartbeat',{...clean,uploads:{...queue,...changes}})).status,422);
    }
    for(const changes of [{eventName:'Private customer'},{eventState:'invented'},{reportedAt:'bad'}]) {
        assert.equal((await h.request('/v1/heartbeat',{...clean,...changes})).status,422);
    }
    assert.equal((await h.request('/v1/heartbeat',{...clean,incidents:['uploads']})).status,422);
}));

test('failed command replies have bounded retries and retained exhausted evidence',()=>withMonitor(async h=>{
    h.fail=true;
    await h.telegram(update(90,'/status'));await h.tick();
    for(let i=0;i<7;i++) {await h.db.prepare('UPDATE telegram_commands SET next_at=0').run();await h.tick();}
    const row=await h.db.prepare('SELECT attempts,delivered_at FROM telegram_commands WHERE update_id=90').first();
    assert.equal(row.attempts,5);assert.equal(row.delivered_at,null);assert.equal(h.messages.length,5);
    assert.equal((await h.telegram(update(90,'/status'))).status,200);await h.tick();
    assert.equal(h.messages.length,5);
    assert.equal((await h.db.prepare('SELECT COUNT(*) c FROM devices').first()).c,0);
}));


test('Telegram retry guidance delays command and incident sends without losing evidence',()=>withMonitor(async h=>{
    h.telegramRetryAfter=7200;
    const before=Date.now();
    await h.telegram(update(501,'/status'));
    await h.request('/v1/heartbeat',{...clean,incidents:['storage']});await h.tick();
    for(const table of ['telegram_commands','notifications']) {
        const row=await h.db.prepare(`SELECT attempts,next_at,delivered_at FROM ${table}`).first();
        assert.equal(row.attempts,1);assert.equal(row.delivered_at,null);
        assert.ok(row.next_at>=before+7200000);
    }
}));

test('fresh receipt of an old device sample is explicitly stale',()=>withMonitor(async h=>{
    await h.request('/v1/heartbeat',{...clean,reportedAt:new Date(Date.now()-3600000).toISOString(),uploads:queue});
    await h.telegram(update(601,'/uploads'));await h.tick();
    const reply=h.messages.find(m=>m.text.includes('Last reported unverified queue:'));
    assert.ok(reply.text.includes('STALE / unavailable'));
    assert.ok(reply.text.includes('Device sample time:'));
}));


test('incident allowlist rejects inherited object names and non-string values',()=>withMonitor(async h=>{
    for(const code of ['constructor','toString','__proto__',{},null]) {
        assert.equal((await h.request('/v1/heartbeat',{...clean,incidents:[code]})).status,422);
    }
    assert.equal((await h.db.prepare('SELECT COUNT(*) c FROM devices').first()).c,0);
    assert.equal(h.messages.length,0);
}));

const readyPrinter={transport:'bluetooth',connection:'connected',readiness:'ready',evidence:'clear'};
function v3(changes={}) {
    return {...clean,telemetryVersion:3,reportedAt:new Date().toISOString(),eventState:'idle',
        printerObservation:readyPrinter,camera:'unknown',guest:'idle',...changes};
}
async function sample(h,changes={}) {
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    const r=await h.request('/v1/heartbeat',v3(changes));
    assert.equal(r.status,200,await r.clone().text());
    await h.tick();
}
const printerState=(changes,other={})=>({printerObservation:{...readyPrinter,...changes},...other});

test('V3 public release identity is explicit and non-sensitive',()=>withMonitor(async h=>{
    const health=await (await h.request('/health')).json();
    assert.equal(health.version,3);assert.equal(health.telemetryVersion,3);
    assert.equal(health.release,'monitoring-v3-2026-10-30');
    assert.deepEqual(Object.keys(health).sort(),['release','service','telemetryVersion','version']);
}));

test('idle disconnect and diagnostic remain observed without urgent notifications',()=>withMonitor(async h=>{
    await sample(h,printerState({connection:'disconnected',readiness:'unavailable'}));
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='printer'").first()).active,1);
    await sample(h,printerState({readiness:'diagnostic_required'}));
    assert.equal(h.messages.length,0);
    await h.telegram(update(700,'/status'));await h.tick();
    assert.ok(h.messages.at(-1).text.includes('diagnostic_required'));
    assert.ok(h.messages.at(-1).text.includes('NOT VERIFIED'));
}));

test('active disconnect debounces across fresh samples and brief reconnect is quiet',()=>withMonitor(async h=>{
    const down=printerState({connection:'disconnected',readiness:'unavailable'},{eventState:'active'});
    await sample(h,down);assert.equal(h.messages.length,0);
    await sample(h,{eventState:'active'});assert.equal(h.messages.length,0);
    await sample(h,down);
    await h.db.prepare("UPDATE monitoring_observations SET unhealthy_since=? WHERE code='printer'").bind(Date.now()-90000).run();
    await sample(h,down);assert.equal(h.messages.length,1);
    assert.ok(h.messages[0].text.includes('WARNING: Printer needs attention'));
    await sample(h,{eventState:'active'});
    assert.equal(h.messages.length,2);assert.ok(h.messages[1].text.includes('RECOVERED'));
    await sample(h,{eventState:'active'});assert.equal(h.messages.length,2);
}));

test('busy work is not unavailable; explicit recovery bypasses debounce',()=>withMonitor(async h=>{
    await sample(h,printerState({readiness:'busy',evidence:'unknown'},{eventState:'active',guest:'printing'}));
    assert.equal(h.messages.length,0);
    await sample(h,printerState({readiness:'recovery_required',evidence:'unresolved'},{eventState:'active',guest:'recovery_required'}));
    assert.equal(h.messages.length,1);assert.ok(h.messages[0].text.includes('CRITICAL'));
    assert.ok(h.messages[0].text.includes('may or may not have printed'));
    const internal=(await h.db.prepare("SELECT code FROM incidents WHERE active=1 AND code IN ('printer','uncertain_print')").all()).results;
    assert.equal(internal.length,2,'notification correlation must preserve separate underlying facts');
}));

test('reconnection alone cannot clear correlated uncertainty; one evidence-backed recovery',()=>withMonitor(async h=>{
    await sample(h,printerState({connection:'disconnected',readiness:'recovery_required',evidence:'unresolved'}));
    await sample(h,printerState({evidence:'unresolved'}));
    assert.equal(h.messages.length,1,'partial recovery is not full recovery');
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='uncertain_print'").first()).active,1);
    await sample(h);
    assert.equal(h.messages.filter(m=>m.text.includes('RECOVERED')).length,1);
    const history=(await h.db.prepare("SELECT code,active FROM incident_history WHERE code IN ('printer','uncertain_print')").all()).results;
    assert.equal(history.length,4);
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM v3_notifications WHERE delivered_at IS NOT NULL').first()).n,2);
}));

test('new print uncertainty upgrades a connectivity warning and independent storage is not suppressed',()=>withMonitor(async h=>{
    const down=printerState({connection:'disconnected',readiness:'unavailable'},{eventState:'active'});
    await sample(h,down);
    await h.db.prepare("UPDATE monitoring_observations SET unhealthy_since=? WHERE code='printer'").bind(Date.now()-90001).run();
    await sample(h,down);assert.equal(h.messages.length,1);
    await sample(h,printerState({connection:'disconnected',readiness:'recovery_required',evidence:'unresolved'},
        {eventState:'active',guest:'printing',storage:'error',incidents:['storage']}));
    assert.equal(h.messages.filter(m=>m.text.includes('Printer needs attention')).length,2);
    assert.ok(h.messages.some(m=>m.text.includes('CRITICAL: Printer')));
    assert.ok(h.messages.some(m=>m.text.includes('Critical local storage')));
}));

test('unknown connection cannot hide standalone physical uncertainty',()=>withMonitor(async h=>{
    await sample(h,printerState({connection:'unknown',readiness:'unknown',evidence:'unresolved'}));
    assert.equal(h.messages.length,1);assert.ok(h.messages[0].text.includes('requires review'));
    await sample(h,printerState({connection:'unknown',readiness:'unknown',evidence:'unknown'}));
    assert.equal(h.messages.length,1);
    await sample(h);
    assert.equal(h.messages.filter(m=>m.text.includes('RECOVERED')).length,1);
}));

test('missing V3 fields and downgraded legacy samples cannot erase V3 printer evidence',()=>withMonitor(async h=>{
    await sample(h,printerState({evidence:'unresolved'}));
    await sample(h,{printerObservation:null,camera:null});
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    assert.equal((await h.request('/v1/heartbeat',clean)).status,200);await h.tick();
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='uncertain_print'").first()).active,1);
    assert.equal((await h.db.prepare("SELECT value FROM monitoring_observations WHERE code='uncertain_print'").first()).value,null);
    assert.equal(h.messages.length,1);
    await h.telegram(update(701,'/incidents'));await h.tick();
    assert.ok(h.messages.at(-1).text.includes('current evidence UNKNOWN'));
    await sample(h);assert.equal(h.messages.filter(m=>m.text.includes('RECOVERED')).length,1);
}));

test('missing queue or failed queue read preserves gallery incident, explicit zero clears it',()=>withMonitor(async h=>{
    await sample(h,{uploads:queue});
    await sample(h,{storage:'error',incidents:['storage']});
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='uploads'").first()).active,1);
    assert.ok(!h.messages.some(m=>m.text.includes('RECOVERED: Gallery')));
    await sample(h,{uploads:{pending:0,uploading:0,verifying:0,attention:0}});
    assert.equal(h.messages.filter(m=>m.text.includes('RECOVERED: Gallery')).length,1);
}));

test('old samples cannot clear equipment or restore missing contact',()=>withMonitor(async h=>{
    const oldTime=new Date(Date.now()-3600000).toISOString();
    await h.request('/v1/heartbeat',{...clean,incidents:['uncertain_print']});await h.tick();
    await h.db.prepare('UPDATE devices SET last_seen=?').bind(Date.now()-3600000).run();await h.tick();
    await h.request('/v1/heartbeat',v3({reportedAt:oldTime}));await h.tick();
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='uncertain_print'").first()).active,1);
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='offline'").first()).active,1);
    assert.ok(!h.messages.some(m=>m.text.includes('RECOVERED')));
    await sample(h);
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='offline'").first()).active,0);
    assert.ok(h.messages.some(m=>m.text.includes('Monitoring contact was restored')));
}));

test('out-of-order device sample is rejected without replacing newer observations',()=>withMonitor(async h=>{
    await sample(h);
    const original=await h.db.prepare('SELECT state_json FROM devices').first();
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    const r=await h.request('/v1/heartbeat',v3({reportedAt:new Date(Date.now()-60000).toISOString(),incidents:['storage']}));
    assert.deepEqual(await r.json(),{accepted:false,reason:'older_sample'});
    assert.equal((await h.db.prepare('SELECT state_json FROM devices').first()).state_json,original.state_json);
}));

test('heartbeat thresholds are event-aware at exact boundaries and no enrollment is quiet',()=>withMonitor(async h=>{
    await h.tick();assert.equal(h.messages.length,0);
    for(const [eventState,limit] of [['active',600000],['idle',900000],['paused',900000]]) {
        await sample(h,{eventState});
        const fixed=Date.now()-limit;
        await h.db.prepare('UPDATE devices SET last_seen=?,state_json=?').bind(fixed,JSON.stringify(v3({eventState,reportedAt:new Date(fixed).toISOString()}))).run();
        await h.tick(fixed+limit-1);
        assert.notEqual((await h.db.prepare("SELECT active FROM incidents WHERE code='offline'").first())?.active,1);
        await h.tick(fixed+limit);
        assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='offline'").first()).active,1);
        await sample(h,{eventState});
    }
    assert.equal(h.messages.filter(m=>m.text.includes('WARNING: Carlo heartbeat missing')).length,3);
}));

test('suspension and intermittent network are contact uncertainty, never equipment diagnoses',()=>withMonitor(async h=>{
    await sample(h,{eventState:'active',camera:'ready'});
    await h.db.prepare('UPDATE devices SET last_seen=?').bind(Date.now()-11*60000).run();
    await h.tick();await h.tick();
    assert.equal(h.messages.length,1);assert.ok(h.messages[0].text.includes('Current device/equipment state UNKNOWN'));
    assert.ok(h.messages[0].text.includes('foregrounded'));
    await sample(h,{eventState:'active',camera:'unknown'});
    assert.ok(h.messages.at(-1).text.includes('Monitoring contact was restored'));
    await h.tick();assert.equal(h.messages.length,2,'foreground restoration does not flap before the overdue threshold');
}));

test('camera initialization and legitimate prolonged guest interaction never raise stalls',()=>withMonitor(async h=>{
    for(const camera of ['unknown','initializing','ready']) await sample(h,{eventState:'active',camera,guest:'guest_in_progress',activityAt:new Date(Date.now()-3600000).toISOString()});
    assert.equal(h.messages.length,0);
    await sample(h,{eventState:'active',camera:'interrupted',guest:'capture_waiting'});
    assert.equal(h.messages.length,1);assert.ok(h.messages[0].text.includes('Camera needs attention'));
    await sample(h,{eventState:'active',camera:'unknown'});assert.equal(h.messages.length,1);
    await sample(h,{eventState:'active',camera:'ready'});assert.equal(h.messages.filter(m=>m.text.includes('RECOVERED')).length,1);
}));

test('permission denial is observational while idle and warns in an active event',()=>withMonitor(async h=>{
    await sample(h,{camera:'permission_denied'});assert.equal(h.messages.length,0);
    await sample(h,{camera:'permission_denied',eventState:'active'});assert.equal(h.messages.length,1);
    await sample(h,{camera:'unavailable',eventState:'active'});assert.equal(h.messages.length,1);
    await sample(h,{camera:'recovery_required',eventState:'active'});assert.equal(h.messages.length,1);
    await sample(h,{camera:'initializing',eventState:'active'});assert.equal(h.messages.length,1);
}));

test('concurrent heartbeat/Cron evaluations cannot duplicate an episode',()=>withMonitor(async h=>{
    const responses=await Promise.all(Array.from({length:8},()=>h.request('/v1/heartbeat',v3(printerState({evidence:'unresolved'})))));
    assert.equal(responses.filter(r=>r.status===200).length,1);
    assert.ok(responses.every(r=>[200,429,503].includes(r.status)));
    await Promise.all([h.tick(),h.tick()]);await h.tick();
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM v3_notifications').first()).n,1);
    assert.equal(h.messages.length,1);
}));

test('Worker/database restart retains correlation, replay protection and pending replies',()=>withMonitor(async h=>{
    h.fail=true;
    await sample(h,printerState({readiness:'recovery_required',evidence:'unresolved'}));
    await h.telegram(update(900,'/status'));await h.tick();
    const initial=(await h.db.prepare('SELECT COUNT(*) n FROM v3_notifications').first()).n;
    await h.restart();h.fail=false;
    await h.db.prepare('UPDATE v3_notifications SET next_at=0').run();
    await h.db.prepare('UPDATE telegram_commands SET next_at=0').run();
    await h.tick();
    await sample(h,printerState({evidence:'unresolved'}));
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM v3_notifications').first()).n,initial);
    assert.equal((await h.telegram(update(900,'/status'))).status,200);
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM telegram_commands').first()).n,1);
    await sample(h);
    assert.equal(h.messages.filter(m=>m.text.includes('RECOVERED: Printer')).length,1);
},false,{persist:true}));

test('stale warning retries are superseded before later recovery or new urgent work',()=>withMonitor(async h=>{
    h.fail=true;
    await sample(h,printerState({evidence:'unresolved'}));
    await sample(h);
    h.fail=false;
    await h.db.prepare('UPDATE v3_notifications SET next_at=0').run();
    await sample(h,{storage:'error',incidents:['storage']});
    const row=await h.db.prepare('SELECT delivered_at,superseded_at FROM v3_notifications WHERE active=1').first();
    assert.equal(row.delivered_at,null);assert.ok(row.superseded_at);
    assert.equal(h.messages.filter(m=>m.text.includes('Physical print outcome uncertain')).length,1,'only original failed attempt');
    assert.ok(h.messages.at(-1).text.includes('Critical local storage'));
    assert.ok(!h.messages.some(m=>m.text.includes('RECOVERED: Printer')),'unsent alerts have no spurious recovery');
}));

test('atomic transition failure cannot enqueue a misleading recovery',()=>withMonitor(async h=>{
    await sample(h,printerState({evidence:'unresolved'}));
    await h.db.prepare("CREATE TRIGGER fail_transition BEFORE UPDATE ON incidents BEGIN SELECT RAISE(ABORT,'synthetic disk failure'); END").run();
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    const previous=await h.db.prepare('SELECT state_json FROM devices').first();
    assert.equal((await h.request('/v1/heartbeat',v3())).status,503);
    assert.deepEqual(await h.db.prepare('SELECT state_json FROM devices').first(),previous,'failed request cannot replace accepted device evidence');
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='uncertain_print'").first()).active,1);
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM v3_notifications WHERE active=0').first()).n,0);
    await h.db.prepare('DROP TRIGGER fail_transition').run();
    await sample(h);assert.equal(h.messages.filter(m=>m.text.includes('RECOVERED')).length,1);
}));

test('V3 schema rejects unnegotiated dimensions, free text and forged observations',()=>withMonitor(async h=>{
    for(const changes of [
        {telemetryVersion:2},{printerObservation:{...readyPrinter,connection:'healthy'}},
        {printerObservation:{...readyPrinter,token:'secret'}},{camera:'private log'},
        {guest:'session-123'},{reportedAt:null}, {printerObservation:[]}
    ]) assert.equal((await h.request('/v1/heartbeat',v3(changes))).status,422);
    assert.equal((await h.request('/v1/heartbeat',{...clean,camera:'ready'})).status,422);
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM devices').first()).n,0);
}));

test('edited messages, forwarded legacy formats and recovery commands remain forbidden',()=>withMonitor(async h=>{
    assert.equal((await h.telegram({...update(920),edited_message:update(920).message})).status,403);
    assert.equal((await h.telegram(update(921,'/status',{forward_from:{id:ownerChat}}))).status,403);
    for(const command of ['/acknowledge','/restart','/retry','/reprint','/payment','/status extra']) await h.telegram(update(922,command));
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM telegram_commands').first()).n,0);
}));

test('V2 migration preserves existing rows and combines already-delivered legacy recovery',()=>withMonitor(async h=>{
    const legacy=await h.db.prepare("SELECT id,attempts,delivered_at FROM notifications WHERE id='old-printer'").first();
    assert.equal(legacy.id,'old-printer');assert.equal(legacy.attempts,1);assert.ok(legacy.delivered_at>0);
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM telegram_commands').first()).n,1);
    await sample(h);
    assert.equal(h.messages.filter(m=>m.text.includes('RECOVERED: Printer')).length,1);
    assert.deepEqual(await h.db.prepare("SELECT id,attempts,delivered_at FROM notifications WHERE id='old-printer'").first(),legacy);
},false,{beforeV3:async db=>{
    await db.batch([
        db.prepare("INSERT INTO incidents VALUES('printer',1,100)"),
        db.prepare("INSERT INTO incidents VALUES('uncertain_print',1,100)"),
        db.prepare("INSERT INTO notifications(id,code,active,created_at,attempts,next_at,delivered_at) VALUES('old-printer','printer',1,?,1,?,?)").bind(Date.now()-60000,Date.now()-60000,Date.now()-60000),
        db.prepare("INSERT INTO telegram_commands(update_id,created_at,reply_text,next_at,attempts) VALUES(999,100,'durable reply',0,5)"),
        db.prepare("INSERT INTO telegram_rate VALUES(100,1)")
    ]);
}}));

test('real V2 Worker rollback preserves pending V3 printer queue and command/replay data',()=>withMonitor(async h=>{
    h.fail=true;
    await sample(h,printerState({evidence:'unresolved'}));
    await h.telegram(update(1001,'/status'));await h.tick();
    const before=(await h.db.prepare('SELECT * FROM v3_notifications').all()).results;
    await h.restart(true);
    assert.equal((await (await h.request('/health')).json()).telemetryVersion,2,'test runs the frozen V2 production module');
    assert.equal((await h.request('/v1/heartbeat',v3())).status,422,'V3 client must negotiate/fall back');
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    assert.equal((await h.request('/v1/heartbeat',clean)).status,200,'legacy fallback enrolls without touching new schema');
    h.fail=false;
    await h.db.prepare('UPDATE telegram_commands SET next_at=0').run();
    await (await h.request('/v1/overview',null,owner)).json();
    assert.deepEqual((await h.db.prepare('SELECT * FROM v3_notifications').all()).results,before);
    assert.equal((await h.telegram(update(1001,'/status'))).status,200);
    await h.restart();await h.tick();
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM telegram_commands WHERE update_id=1001').first()).n,1);
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM v3_notifications').first()).n,1);
},false,{persist:true}));

test('a V3 app compatibility payload is accepted by real V2 Worker',()=>withMonitor(async h=>{
    await h.restart(true);
    const state=v3({eventState:'active',uploads:queue});
    for(const key of ['telemetryVersion','printerObservation','camera','guest']) delete state[key];
    assert.equal((await h.request('/v1/heartbeat',state)).status,200);
    await h.restart();
    assert.equal((await (await h.request('/v1/overview',null,owner)).json()).state.uploads.pending,3);
},false,{persist:true}));

test('recovery retries require fresh known evidence even after a prior valid clear',()=>withMonitor(async h=>{
    await sample(h,printerState({evidence:'unresolved'}));
    h.fail=true;await sample(h);
    h.fail=false;const attempts=h.messages.length;
    await sample(h,{printerObservation:null});
    await h.db.prepare('UPDATE v3_notifications SET next_at=0').run();await h.tick();
    assert.equal(h.messages.length,attempts,'unknown cannot release a pending recovery');
    await sample(h);await h.db.prepare('UPDATE v3_notifications SET next_at=0').run();await h.tick();
    assert.equal(h.messages.length,attempts+1);
    assert.ok(h.messages.at(-1).text.includes('RECOVERED'));
}));

test('exhausted command replies survive retention and failed reconciliation read cannot recover',()=>withMonitor(async h=>{
    await h.db.prepare('INSERT INTO telegram_commands(update_id,created_at,reply_text,attempts,next_at) VALUES(1100,?,?,5,0)').bind(Date.now()-8*86400000,'retained failure').run();
    h.health={environment:'live',liveEnabled:true,reconciliationFresh:false};await h.tick();
    h.health={environment:'live',liveEnabled:true};await h.tick();
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM telegram_commands WHERE update_id=1100').first()).n,1);
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='reconciliation'").first()).active,1);
    assert.ok(!h.messages.some(m=>m.text.includes('RECOVERED: Backend reconciliation')));
},true));

// Test-only proxy counts D1 API subrequests, including waitUntil delivery work. Cloudflare
// counts batch() once; enforce 40 here to leave margin under the Free plan's 50-query ceiling.
function budgetScript(source,takeover=false) {
    return source.replace('export default {','const productionWorker = {')+`
const budgetSamples=[];
const takeoverMode=${takeover};
function budgetEnv(env) {
    let count=0;
    const charge=()=>{if(++count>40) throw new Error('test D1 subrequest budget exceeded');};
    const wrap=(statement,sql)=>({__statement:statement,__sql:sql,bind(...args){return wrap(statement.bind(...args),sql);},
        first(...args){charge();return statement.first(...args);},all(...args){charge();return statement.all(...args);},
        run(...args){charge();return statement.run(...args);}});
    return {env:{...env,DB:{prepare(sql){return wrap(env.DB.prepare(sql),sql);},async batch(items){charge();const result=await env.DB.batch(items.map(i=>i.__statement));if(takeoverMode && items.some(i=>i.__sql==='SELECT * FROM monitoring_observations')) await env.DB.prepare("UPDATE monitoring_locks SET owner='newer-invocation' WHERE id='state'").run();return result;}}},get count(){return count;}};
}
export default {
    async fetch(request,env,ctx) {
        if(new URL(request.url).pathname==='/__budget') return Response.json(budgetSamples);
        const budget=budgetEnv(env),pending=[];
        const result=await productionWorker.fetch(request,budget.env,{waitUntil(p){pending.push(p);}});
        await Promise.all(pending);budgetSamples.push(budget.count);
        return result;
    },
    async scheduled(controller,env,ctx) {
        const budget=budgetEnv(env),pending=[];
        await productionWorker.scheduled(controller,budget.env,{waitUntil(p){pending.push(p);}});
        await Promise.all(pending);budgetSamples.push(budget.count);
    }
};`;
}

test('worst-case alert and command work stays below Free D1 invocation budget',()=>withMonitor(async h=>{
    h.fail=true;h.healthStatus=503;
    await sample(h,printerState({readiness:'recovery_required',evidence:'unresolved'},
        {eventState:'active',guest:'printing',storage:'error',incidents:['storage','paid_blocked','review','verification','paused'],uploads:queue,camera:'unavailable'}));
    await h.db.batch(Array.from({length:3},(_,i)=>h.db.prepare('INSERT INTO telegram_commands(update_id,created_at,reply_text,next_at) VALUES(?,?,?,0)').bind(1200+i,Date.now(),'synthetic durable reply')));
    await h.db.prepare('UPDATE notifications SET next_at=0').run();
    await h.db.prepare('UPDATE v3_notifications SET next_at=0').run();
    await h.tick();
    await h.telegram(update(1300,'/incidents'));await h.tick();
    const counts=await (await h.request('/__budget')).json();
    assert.ok(counts.length>=4);assert.ok(counts.every(c=>c<=40),JSON.stringify(counts));
    assert.ok(h.messages.some(m=>m.text.includes('CRITICAL')));
},true,{budget:true}));

test('a failed evidence store cannot clear payment or event-recovery observations',()=>withMonitor(async h=>{
    await sample(h,{incidents:['paid_blocked','paused','review'],eventState:'recovery'});
    await sample(h,{storage:'error',incidents:['storage'],eventState:'recovery'});
    for(const code of ['paid_blocked','paused','review']) {
        assert.equal((await h.db.prepare('SELECT active FROM incidents WHERE code=?').bind(code).first()).active,1);
        assert.equal((await h.db.prepare('SELECT value FROM monitoring_observations WHERE code=?').bind(code).first()).value,null);
    }
    assert.ok(!h.messages.some(m=>m.text.includes('RECOVERED')));
}));

test('camera notifications also survive real V2 rollback without undefined alert text',()=>withMonitor(async h=>{
    h.fail=true;await sample(h,{eventState:'active',camera:'unavailable'});
    const initial=(await h.db.prepare("SELECT * FROM v3_notifications WHERE code='camera'").all()).results;
    assert.equal(initial.length,1);
    await h.restart(true);h.fail=false;
    await h.tick();
    assert.deepEqual((await h.db.prepare("SELECT * FROM v3_notifications WHERE code='camera'").all()).results,initial);
    assert.ok(!h.messages.some(m=>m.text.includes('undefined')));
},false,{persist:true}));

test('a new connection failure during ongoing uncertainty is visible and partial clearing never recovers',()=>withMonitor(async h=>{
    await sample(h,printerState({evidence:'unresolved'}));
    await sample(h,printerState({connection:'disconnected',readiness:'unavailable',evidence:'unresolved'},{eventState:'active'}));
    assert.equal(h.messages.filter(m=>m.text.includes('Printer needs attention')).length,2);
    await sample(h,printerState({evidence:'unresolved'}));
    assert.ok(!h.messages.some(m=>m.text.includes('RECOVERED')));
    await sample(h,printerState({connection:'disconnected',readiness:'unavailable',evidence:'unresolved'},{eventState:'active'}));
    assert.equal(h.messages.filter(m=>m.text.includes('Printer needs attention')).length,3,'a recurring independent connection problem is a new component transition');
}));

test('active print escalation is retained as last-known when the next observation is unknown',()=>withMonitor(async h=>{
    await sample(h,printerState({readiness:'recovery_required',evidence:'unresolved'},{eventState:'active',guest:'printing'}));
    await sample(h,{printerObservation:null});
    assert.equal((await h.db.prepare("SELECT severity FROM notification_episodes WHERE code='printer_attention'").first()).severity,'CRITICAL');
    assert.equal(h.messages.length,1);
}));

test('lost state-lease ownership aborts transitions instead of overwriting newer evidence',()=>withMonitor(async h=>{
    assert.equal((await h.request('/v1/heartbeat',v3({incidents:['storage'],storage:'error'}))).status,503);
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM incidents').first()).n,0);
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM notifications').first()).n,0);
    assert.equal((await h.db.prepare("SELECT owner FROM monitoring_locks WHERE id='state'").first()).owner,'newer-invocation','the late finally block cannot release another owner');
    assert.equal((await h.db.prepare('SELECT COUNT(*) n FROM devices').first()).n,0,'failed atomic ingestion is not an accepted heartbeat');
},false,{leaseTakeover:true}));

test('a recovery cannot overtake an in-flight warning across separate requests',()=>withMonitor(async h=>{
    const gate=h.holdNextTelegram();
    assert.equal((await h.request('/v1/heartbeat',v3(printerState({evidence:'unresolved'})))).status,200);
    await gate.started;
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    assert.equal((await h.request('/v1/heartbeat',v3())).status,200);
    assert.equal((await h.db.prepare("SELECT active FROM notification_episodes WHERE code='printer_attention'").first()).active,0);
    assert.equal(h.messages.length,1,'recovery is still queued while original send is in flight');
    gate.release();await h.tick();await h.tick();
    assert.equal(h.messages.length,2);
    assert.ok(h.messages[0].text.includes('WARNING'));
    assert.ok(h.messages[1].text.includes('RECOVERED'));
}));

test('new critical evidence outranks an older low-priority retry backlog',()=>withMonitor(async h=>{
    h.fail=true;await sample(h,{incidents:['review','verification','paused'],uploads:queue});
    h.fail=false;const offset=h.messages.length;
    await h.db.prepare('UPDATE notifications SET next_at=0').run();
    await sample(h,{storage:'error',incidents:['storage','review','verification','paused'],uploads:queue});
    assert.ok(h.messages[offset].text.includes('CRITICAL: Critical local storage'));
}));

test('explicit V3 unknown event context remains unknown and does not imply active urgency',()=>withMonitor(async h=>{
    await sample(h,{eventState:'unknown'});
    await h.telegram(update(1400,'/event'));await h.tick();
    assert.ok(h.messages.at(-1).text.includes('Event state: unknown'));
    assert.equal((await h.request('/v1/heartbeat',{...clean,eventState:'unknown'})).status,422,'older schema contract is unchanged');
}));

test('an active guest needing recovery with unavailable transport warns promptly without inventing uncertain paper',()=>withMonitor(async h=>{
    await sample(h,printerState({connection:'disconnected',readiness:'unavailable'},{eventState:'active',guest:'recovery_required'}));
    assert.equal(h.messages.length,1,'current guest recovery plus unavailable transport bypasses transient debounce');
    assert.ok(h.messages[0].text.includes('WARNING'));
    assert.ok(h.messages[0].text.includes('Receipt printing may be delayed'));
    assert.ok(!h.messages[0].text.includes('may or may not have printed'));
    assert.notEqual((await h.db.prepare("SELECT active FROM incidents WHERE code='uncertain_print'").first())?.active,1);
}));

test('legacy V2 idle context is quiet while context-free V1 printer warnings remain conservative',()=>withMonitor(async h=>{
    const legacyDown={...clean,printer:'unavailable',incidents:['printer']};
    await h.request('/v1/heartbeat',{...legacyDown,eventState:'idle'});await h.tick();
    assert.equal(h.messages.length,0);
    await h.db.prepare('UPDATE devices SET last_seen=0').run();
    await h.request('/v1/heartbeat',legacyDown);await h.tick();
    assert.equal(h.messages.length,1,'unknown legacy context must not silently hide potential unavailability');
}));
