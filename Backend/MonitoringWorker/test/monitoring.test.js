import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
const require=createRequire(new URL('../../PaymentsWorker/package.json',import.meta.url));
const {Miniflare,convertV4MiniflareOptions}=require('miniflare');
const device='d'.repeat(48),owner='o'.repeat(48);
const clean={mode:'regular',network:'online',payment:'ready',printer:'ready',storage:'ready',incidents:[]};

async function withMonitor(body) {
    const messages=[];let failTelegram=false;
    const mf=new Miniflare(convertV4MiniflareOptions({modules:true,script:readFileSync(new URL('../src/index.js',import.meta.url),'utf8'),compatibilityDate:'2026-10-01',d1Databases:['DB'],bindings:{DEVICE_TOKEN:device,OWNER_READ_TOKEN:owner,TELEGRAM_BOT_TOKEN:'test-only',TELEGRAM_CHAT_ID:'owner-only',STALE_SECONDS:'900'},outboundService:async request=>{
        messages.push(await request.json());return Response.json({ok:!failTelegram},{status:failTelegram?503:200});
    }}));
    const db=await mf.getD1Database('DB');
    await db.exec(readFileSync(new URL('../migrations/0001_monitoring.sql',import.meta.url),'utf8'));
    const h={db,messages,set fail(value){failTelegram=value;},async request(path,body,token=device){return mf.dispatchFetch('https://monitor.test'+path,{method:body?'POST':'GET',headers:{authorization:'Bearer '+token,'content-type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});},async tick(time=Date.now()){return (await mf.getWorker()).scheduled({cron:'*/5 * * * *',scheduledTime:new Date(time)});}};
    try{await body(h);}finally{await mf.dispose();}
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
