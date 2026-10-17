import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync, readdirSync } from 'node:fs';
const require=createRequire(new URL('../../PaymentsWorker/package.json',import.meta.url));
const {Miniflare,convertV4MiniflareOptions}=require('miniflare');
const device='d'.repeat(48),owner='o'.repeat(48);
const clean={mode:'regular',network:'online',payment:'ready',printer:'ready',storage:'ready',incidents:[]};

async function withMonitor(body, paymentsHealth=false) {
    const messages=[],healthCalls=[];let failTelegram=false,healthStatus=200,health={environment:'live',liveEnabled:true,reconciliationFresh:true};
    const mf=new Miniflare(convertV4MiniflareOptions({modules:true,script:readFileSync(new URL('../src/index.js',import.meta.url),'utf8'),compatibilityDate:'2026-10-01',d1Databases:['DB'],bindings:{DEVICE_TOKEN:device,OWNER_READ_TOKEN:owner,TELEGRAM_BOT_TOKEN:'test-only',TELEGRAM_CHAT_ID:'owner-only',STALE_SECONDS:'900',...(paymentsHealth?{PAYMENTS_HEALTH_URL:'https://payments.test/v1/monitor-health',PAYMENTS_HEALTH_TOKEN:'health-read-only'}:{})},outboundService:async request=>{
        if(new URL(request.url).hostname==='payments.test') {
            healthCalls.push({authorization:request.headers.get('authorization')});
            return Response.json(health,{status:healthStatus});
        }
        messages.push(await request.json());return Response.json({ok:!failTelegram},{status:failTelegram?503:200});
    }}));
    try {
        const db=await mf.getD1Database('DB');
        for(const migration of readdirSync(new URL('../migrations/',import.meta.url)).filter(f=>f.endsWith('.sql')).sort()) {
            await db.exec(readFileSync(new URL('../migrations/'+migration,import.meta.url),'utf8').replace(/^--.*$/gm,'').trim());
        }
        const h={db,messages,healthCalls,set fail(value){failTelegram=value;},set healthStatus(value){healthStatus=value;},set health(value){health=value;},async request(path,body,token=device){return mf.dispatchFetch('https://monitor.test'+path,{method:body?'POST':'GET',headers:{authorization:'Bearer '+token,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});},async tick(time=Date.now()){return (await mf.getWorker()).scheduled({cron:'*/5 * * * *',scheduledTime:new Date(time)});}};
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
