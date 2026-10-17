const HEADERS = { 'content-type': 'application/json', 'cache-control': 'no-store' };
const CODES = {
    offline: 'Carlo heartbeat missing', backend: 'Payment backend unavailable', verification: 'Payment confirmation repeatedly failing',
    review: 'Payment requires owner review', paid_blocked: 'Verified payment waiting before camera', printer: 'Printer unavailable or recovery required',
    uncertain_print: 'Physical print outcome uncertain', storage: 'Critical local storage issue', paused: 'Booth paused or event recovery required',
    reconciliation: 'Backend reconciliation stale'
};
const VALID = { mode: ['regular','event','paused','recovery'], network: ['online','offline','unknown'], payment: ['ready','unavailable','review'], printer: ['ready','recovery','uncertain','unavailable'], storage: ['ready','error'] };
const response = (v, status = 200) => new Response(JSON.stringify(v), {status, headers: HEADERS});

export default {
    async fetch(request, env, ctx) {
        try {
            const path = new URL(request.url).pathname;
            if (path === '/health' && request.method === 'GET') return response({service:'made-to-keep-monitor',version:1});
            if (path === '/v1/heartbeat' && request.method === 'POST') {
                if (!await authorized(request, env.DEVICE_TOKEN)) return response({error:'unauthorized'},401);
                if (Number(request.headers.get('content-length') || 0) > 2048) return response({error:'too_large'},413);
                const text = await request.text();
                if (text.length > 2048) return response({error:'too_large'},413);
                let state; try { state = validate(JSON.parse(text)); } catch { return response({error:'invalid_telemetry'},422); }
                const time = Date.now();
                // One configured device; authenticated storms cannot create arbitrary rows.
                const previous = await env.DB.prepare('SELECT last_seen FROM devices WHERE id=?').bind('carlo').first();
                if (previous && time - previous.last_seen < 30_000) return response({error:'rate_limited'},429);
                await env.DB.prepare('INSERT INTO devices(id,last_seen,state_json) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen,state_json=excluded.state_json').bind('carlo',time,JSON.stringify(state)).run();
                await syncIncidents(env, {...Object.fromEntries(Object.keys(CODES).filter(c=>!['backend','reconciliation'].includes(c)).map(c=>[c,state.incidents.includes(c)])), offline:false}, time);
                ctx.waitUntil(deliver(env,time));
                return response({accepted:true,serverTime:new Date(time).toISOString()});
            }
            if (!await authorized(request, env.OWNER_READ_TOKEN)) return response({error:'unauthorized'},401);
            if (path === '/v1/overview' && request.method === 'GET') {
                const device = await env.DB.prepare('SELECT last_seen,state_json FROM devices WHERE id=?').bind('carlo').first();
                const incidents = (await env.DB.prepare('SELECT code,active,changed_at FROM incidents WHERE active=1').all()).results;
                const delivery = await env.DB.prepare('SELECT COUNT(*) pending,COALESCE(SUM(CASE WHEN attempts>=5 THEN 1 ELSE 0 END),0) failed FROM notifications WHERE delivered_at IS NULL AND superseded_at IS NULL').first();
                return response({device:'Carlo',online:!!device && Date.now()-device.last_seen<Number(env.STALE_SECONDS || 900)*1000,lastHeartbeat:device?.last_seen || null,state:device?JSON.parse(device.state_json):null,incidents,delivery});
            }
            if (path === '/v1/test-notification' && request.method === 'POST') {
                const key = 'owner-test-'+Math.floor(Date.now()/3600000);
                await env.DB.prepare('INSERT OR IGNORE INTO notifications(id,code,active,created_at,next_at) VALUES(?,?,?,?,?)').bind(key,'owner_test',1,Date.now(),Date.now()).run();
                await deliver(env,Date.now());
                return response({queued:true});
            }
            return response({error:'not_found'},404);
        } catch { return response({error:'monitor_unavailable'},503); }
    },
    async scheduled(controller,env,ctx) { ctx.waitUntil(check(env,controller.scheduledTime)); }
};

export function validate(value) {
    if (!value || typeof value!=='object' || Array.isArray(value) || Object.keys(value).some(k=>![...Object.keys(VALID),'incidents','eventReference'].includes(k))) throw new Error('invalid');
    const clean = {};
    for (const [key,values] of Object.entries(VALID)) {
        if (!values.includes(value[key])) throw new Error('invalid');
        clean[key] = value[key];
    }
    if (!Array.isArray(value.incidents) || value.incidents.length>10 || value.incidents.some(code=>!CODES[code] || ['offline','backend','reconciliation'].includes(code))) throw new Error('invalid');
    clean.incidents = [...new Set(value.incidents)].sort();
    if (value.eventReference != null && !/^[a-zA-Z0-9-]{1,40}$/.test(value.eventReference)) throw new Error('invalid');
    clean.eventReference = value.eventReference || null;
    return clean;
}

async function authorized(request,secret) {
    if (!secret || secret.length<32) return false;
    const supplied = request.headers.get('authorization') || '';
    if (supplied.length>600) return false;
    const hash = async s => new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
    const [a,b] = await Promise.all([hash(supplied),hash('Bearer '+secret)]);
    return a.reduce((diff,v,i)=>diff | (v^b[i]),0)===0;
}

export async function syncIncidents(env, states, time=Date.now()) {
    for (const [code,active] of Object.entries(states)) {
        if (!CODES[code]) continue;
        const old = await env.DB.prepare('SELECT active,changed_at FROM incidents WHERE code=?').bind(code).first();
        if (old?.active===+active || (!old && !active)) continue;
        // Guard on the previous value inside one atomic batch; concurrent Cron/heartbeat changes
        // cannot enqueue the same transition twice.
        const id = `${code}:${+active}:${old?.changed_at || 0}`;
        await env.DB.batch([
            env.DB.prepare(`INSERT OR IGNORE INTO notifications(id,code,active,created_at,next_at)
                SELECT ?,?,?,?,? WHERE COALESCE((SELECT active FROM incidents WHERE code=?),-1)=?`)
                .bind(id,code,+active,time,time,code,old?.active ?? -1),
            env.DB.prepare('INSERT INTO incidents(code,active,changed_at) VALUES(?,?,?) ON CONFLICT(code) DO UPDATE SET active=excluded.active,changed_at=excluded.changed_at WHERE incidents.active<>excluded.active').bind(code,+active,time)
        ]);
    }
}

export async function check(env,time=Date.now()) {
    const device = await env.DB.prepare('SELECT last_seen FROM devices WHERE id=?').bind('carlo').first();
    // No alarm before Carlo has enrolled. Once enrolled, missing heartbeats stay visible.
    if (device) await syncIncidents(env,{offline:time-device.last_seen>Number(env.STALE_SECONDS || 900)*1000},time);
    if (env.PAYMENTS_HEALTH_URL) {
        try {
            const r = await fetch(env.PAYMENTS_HEALTH_URL,{headers:{authorization:'Bearer '+env.PAYMENTS_HEALTH_TOKEN},signal:AbortSignal.timeout(8000)});
            if (!r.ok) throw new Error('unavailable');
            const h = await r.json();
            if (h.environment!=='live' || h.liveEnabled!==true) throw new Error('wrong_environment');
            await syncIncidents(env,{backend:false,reconciliation:!h.reconciliationFresh},time);
        } catch { await syncIncidents(env,{backend:true},time); }
    }
    await deliver(env,time);
    // Bound completed delivery history; current incidents and exhausted retries stay visible.
    await env.DB.prepare('DELETE FROM notifications WHERE (delivered_at IS NOT NULL OR superseded_at IS NOT NULL) AND created_at<?').bind(time-30*86400000).run();
}

export async function deliver(env,time=Date.now()) {
    if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) return;
    const due = (await env.DB.prepare('SELECT * FROM notifications WHERE delivered_at IS NULL AND superseded_at IS NULL AND attempts<5 AND next_at<=? AND (lease_until IS NULL OR lease_until<=?) ORDER BY created_at LIMIT 3').bind(time,time).all()).results || [];
    for (const item of due) {
        if (item.code!=='owner_test') {
            const latest = await env.DB.prepare('SELECT active FROM incidents WHERE code=?').bind(item.code).first();
            const sent = await env.DB.prepare('SELECT active,delivered_at FROM notifications WHERE code=? AND delivered_at IS NOT NULL AND attempts>0 ORDER BY delivered_at DESC LIMIT 1').bind(item.code).first();
            if (latest?.active!==item.active || (!item.active && !sent)) {
                // Retried alerts can become obsolete too. Leaving them due would repeatedly
                // occupy the bounded queue and starve newer incidents after an outage.
                await env.DB.prepare('UPDATE notifications SET superseded_at=? WHERE id=? AND delivered_at IS NULL AND (lease_until IS NULL OR lease_until<=?)').bind(time,item.id,time).run();
                continue;
            }
            if (sent && time-sent.delivered_at<15*60_000) {
                await env.DB.prepare('UPDATE notifications SET next_at=? WHERE id=?').bind(sent.delivered_at+15*60_000,item.id).run();
                continue;
            }
        }
        const lease = time+30_000;
        const claim = await env.DB.prepare('UPDATE notifications SET lease_until=?,attempts=attempts+1 WHERE id=? AND delivered_at IS NULL AND superseded_at IS NULL AND attempts=? AND (lease_until IS NULL OR lease_until<=?)').bind(lease,item.id,item.attempts,time).run();
        if (claim.meta.changes!==1) continue;
        const text = item.code==='owner_test' ? 'Made to Keep Studios · monitoring test. Owner alerts are connected. No payment or printing was performed.'
            : `Made to Keep Studios · Carlo\n${item.active?'ATTENTION':'RECOVERED'}: ${CODES[item.code]}\nCheck Booth Status and Equipment & Recovery on Carlo. No customer or payment details are included.`;
        try {
            const r = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({chat_id:env.TELEGRAM_CHAT_ID,text,protect_content:true}),signal:AbortSignal.timeout(8000)});
            if (!r.ok || !(await r.json()).ok) throw new Error('delivery');
            await env.DB.prepare('UPDATE notifications SET delivered_at=?,lease_until=NULL WHERE id=? AND lease_until=?').bind(Date.now(),item.id,lease).run();
        } catch {
            const delay = [60,300,900,3600,3600][Math.min(item.attempts,4)]*1000;
            await env.DB.prepare('UPDATE notifications SET next_at=?,lease_until=NULL WHERE id=? AND lease_until=?').bind(time+delay,item.id,lease).run();
        }
    }
}
