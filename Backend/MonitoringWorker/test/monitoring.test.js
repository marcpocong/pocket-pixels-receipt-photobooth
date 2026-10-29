import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, readdirSync } from 'node:fs';
const require=createRequire(new URL('../../PaymentsWorker/package.json',import.meta.url));
const {Miniflare,convertV4MiniflareOptions}=require('miniflare');
const device='d'.repeat(48),owner='o'.repeat(48),webhook='w'.repeat(48);
const ownerChat=424242;
const clean={mode:'regular',network:'online',payment:'ready',printer:'ready',storage:'ready',incidents:[]};

async function withMonitor(body, paymentsHealth=false) {
    const messages=[],healthCalls=[];let failTelegram=false,telegramRetryAfter=null,healthStatus=200,health={environment:'live',liveEnabled:true,reconciliationFresh:true};
    const mf=new Miniflare(convertV4MiniflareOptions({modules:true,script:readFileSync(new URL('../src/index.js',import.meta.url),'utf8'),compatibilityDate:'2026-10-01',d1Databases:['DB'],bindings:{DEVICE_TOKEN:device,OWNER_READ_TOKEN:owner,TELEGRAM_BOT_TOKEN:'test-only',TELEGRAM_CHAT_ID:String(ownerChat),TELEGRAM_WEBHOOK_SECRET:webhook,STALE_SECONDS:'900',...(paymentsHealth?{PAYMENTS_HEALTH_URL:'https://payments.test/v1/monitor-health',PAYMENTS_HEALTH_TOKEN:'health-read-only'}:{})},outboundService:async request=>{
        if(new URL(request.url).hostname==='payments.test') {
            healthCalls.push({authorization:request.headers.get('authorization')});
            return Response.json(health,{status:healthStatus});
        }
        messages.push(await request.json());if(telegramRetryAfter!=null) return Response.json({ok:false,parameters:{retry_after:telegramRetryAfter}},{status:429});return Response.json({ok:!failTelegram},{status:failTelegram?503:200});
    }}));
    try {
        const db=await mf.getD1Database('DB');
        for(const migration of readdirSync(new URL('../migrations/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort()) {
            for (const statement of readFileSync(new URL('../migrations/'+migration,import.meta.url),'utf8').replace(/^--.*$/gm,'').split(';').map(s=>s.trim()).filter(Boolean)) await db.prepare(statement).run();
        }
        const h={db,messages,healthCalls,set fail(value){failTelegram=value;},set telegramRetryAfter(value){telegramRetryAfter=value;},set healthStatus(value){healthStatus=value;},set health(value){health=value;},async request(path,body,token=device){return mf.dispatchFetch('https://monitor.test'+path,{method:body?'POST':'GET',headers:{authorization:'Bearer '+token,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});},async telegram(body,secret=webhook) {return mf.dispatchFetch('https://monitor.test/v1/telegram',{method:'POST',headers:{'x-telegram-bot-api-secret-token':secret,'content-type':'application/json'},body:typeof body==='string'?body:JSON.stringify(body)});},async tick(time=Date.now()){
            await (await mf.getWorker()).scheduled({cron:'*/5 * * * *',scheduledTime:new Date(time)});
            // Concurrent heartbeat/Cron deliveries hold real leases until outbound work finishes.
            for(let i=0;i<200;i++) {
                const leases=await db.prepare('SELECT (SELECT COUNT(*) FROM notifications WHERE lease_until IS NOT NULL)+(SELECT COUNT(*) FROM telegram_commands WHERE lease_until IS NOT NULL) c').first();
                if(!leases.c) return;
                await new Promise(resolve=>setTimeout(resolve,10));
            }
            assert.fail('monitoring delivery did not settle');
        }};
        await body(h);
    } finally {await mf.dispose();}
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

test('payment backend failures are authenticated, deduplicated and recover after cooldown',()=>withMonitor(async h=>{
    h.healthStatus=503;
    await h.tick();await h.tick();
    assert.equal(h.messages.length,1);
    assert.ok(h.messages[0].text.includes('Payment backend unavailable'));
    assert.equal(h.healthCalls[0].authorization,'Bearer health-read-only');
    h.healthStatus=200;
    await h.tick();
    assert.equal((await h.db.prepare("SELECT active FROM incidents WHERE code='backend'").first()).active,0);
    assert.equal(h.messages.length,1,'recovery respects the notification cooldown');
    await h.tick(Date.now()+16*60_000);
    assert.equal(h.messages.length,2);
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
    for(const changes of [{chat:{id:99,type:'private'}},{chat:{id:ownerChat,type:'group'}},{from:{id:99,is_bot:false}},{from:{id:ownerChat,is_bot:true}},{forward_origin:{type:'user'}},{sender_chat:{id:ownerChat}}]) {
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
