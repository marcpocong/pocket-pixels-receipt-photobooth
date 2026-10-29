const HEADERS = { 'content-type': 'application/json', 'cache-control': 'no-store' };
const CODES = {
    offline: 'Carlo heartbeat missing', backend: 'Payment backend unavailable', verification: 'Payment confirmation repeatedly failing',
    review: 'Payment requires owner review', paid_blocked: 'Verified payment waiting before camera', printer: 'Printer unavailable or recovery required',
    uncertain_print: 'Physical print outcome uncertain', storage: 'Critical local storage issue', paused: 'Booth paused or event recovery required',
    reconciliation: 'Backend reconciliation stale', uploads: 'Gallery delivery needs attention'
};
const VALID = { mode: ['regular','event','paused','recovery'], network: ['online','offline','unknown'], payment: ['ready','unavailable','review'], printer: ['ready','recovery','uncertain','unavailable'], storage: ['ready','error'] };
const response = (v, status = 200) => new Response(JSON.stringify(v), {status, headers: HEADERS});

export default {
    async fetch(request, env, ctx) {
        try {
            const path = new URL(request.url).pathname;
            if (path === '/v1/telegram' && request.method === 'POST') return await telegramWebhook(request,env,ctx);
            if (path === '/health' && request.method === 'GET') return response({service:'made-to-keep-monitor',version:2,telemetryVersion:2});
            if (path === '/v1/heartbeat' && request.method === 'POST') {
                if (!await authorized(request, env.DEVICE_TOKEN)) return response({error:'unauthorized'},401);
                let state;
                try { state = validate(await boundedJSON(request,2048)); }
                catch (error) { return response({error:error.message==='too_large'?'too_large':'invalid_telemetry'},error.message==='too_large'?413:422); }
                const time = Date.now();
                // One configured device; authenticated storms cannot create arbitrary rows.
                const previous = await env.DB.prepare('SELECT last_seen FROM devices WHERE id=?').bind('carlo').first();
                if (previous && time - previous.last_seen < 30_000) return response({error:'rate_limited'},429);
                await env.DB.prepare('INSERT INTO devices(id,last_seen,state_json) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen,state_json=excluded.state_json').bind('carlo',time,JSON.stringify(state)).run();
                await syncIncidents(env, {...Object.fromEntries(Object.keys(CODES).filter(c=>!['backend','reconciliation'].includes(c)).map(c=>[c,state.incidents.includes(c)])), offline:false, uploads:uploadIncident(state)}, time);
                ctx.waitUntil(deliver(env,time));
                return response({accepted:true,serverTime:new Date(time).toISOString()});
            }
            if (!await authorized(request, env.OWNER_READ_TOKEN)) return response({error:'unauthorized'},401);
            if (path === '/v1/overview' && request.method === 'GET') {
                const device = await env.DB.prepare('SELECT last_seen,state_json FROM devices WHERE id=?').bind('carlo').first();
                const incidents = (await env.DB.prepare('SELECT code,active,changed_at FROM incidents WHERE active=1').all()).results;
                const delivery = await env.DB.prepare('SELECT COUNT(*) pending,COALESCE(SUM(CASE WHEN attempts>=5 THEN 1 ELSE 0 END),0) failed FROM notifications WHERE delivered_at IS NULL AND superseded_at IS NULL').first();
                const commands = await env.DB.prepare('SELECT COUNT(*) pending,COALESCE(SUM(CASE WHEN attempts>=5 THEN 1 ELSE 0 END),0) failed FROM telegram_commands WHERE delivered_at IS NULL').first();
                return response({device:'Carlo',online:!!device && Date.now()-device.last_seen<Number(env.STALE_SECONDS || 900)*1000,lastHeartbeat:device?.last_seen || null,state:device?JSON.parse(device.state_json):null,incidents,delivery,commands});
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
    if (!value || typeof value!=='object' || Array.isArray(value) || Object.keys(value).some(k=>![...Object.keys(VALID),'incidents','eventReference','reportedAt','eventState','activityAt','uploads'].includes(k))) throw new Error('invalid');
    const clean = {};
    for (const [key,values] of Object.entries(VALID)) {
        if (!values.includes(value[key])) throw new Error('invalid');
        clean[key] = value[key];
    }
    if (!Array.isArray(value.incidents) || value.incidents.length>10 || value.incidents.some(code=>!CODES[code] || ['offline','backend','reconciliation','uploads'].includes(code))) throw new Error('invalid');
    clean.incidents = [...new Set(value.incidents)].sort();
    if (value.eventReference != null && (typeof value.eventReference!=='string' || !/^[a-zA-Z0-9-]{1,40}$/.test(value.eventReference))) throw new Error('invalid');
    clean.eventReference = value.eventReference || null;
    if (value.reportedAt != null) clean.reportedAt = timestamp(value.reportedAt);
    if (value.activityAt != null) clean.activityAt = timestamp(value.activityAt);
    if (value.eventState != null) {
        if (!['active','paused','idle','recovery'].includes(value.eventState)) throw new Error('invalid');
        clean.eventState = value.eventState;
    }
    if (value.uploads != null) {
        const u=value.uploads;
        if (!u || typeof u!=='object' || Array.isArray(u) || Object.keys(u).some(k=>!['pending','uploading','verifying','attention','oldestAt','activityAt'].includes(k))) throw new Error('invalid');
        const queue={};
        for (const key of ['pending','uploading','verifying','attention']) {
            if (!Number.isSafeInteger(u[key]) || u[key]<0 || u[key]>100000) throw new Error('invalid');
            queue[key]=u[key];
        }
        if (queue.uploading+queue.verifying>1 || queue.attention>queue.pending) throw new Error('invalid');
        for (const key of ['oldestAt','activityAt']) if (u[key]!=null) queue[key]=timestamp(u[key]);
        clean.uploads=queue;
    }
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
            await recordBackendHealth(env,time,true,!!h.reconciliationFresh);
            await syncIncidents(env,{backend:false,reconciliation:!h.reconciliationFresh},time);
        } catch { await recordBackendHealth(env,time,false,null); await syncIncidents(env,{backend:true},time); }
    }
    await deliver(env,time);
    await deliverCommands(env,time);
    await env.DB.prepare('DELETE FROM telegram_rate WHERE window<?').bind(Math.floor(time/60000)-1440).run();
    await env.DB.prepare('DELETE FROM telegram_commands WHERE created_at<?').bind(time-7*86400000).run();
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
            : `Made to Keep Studios · Carlo\n${item.active?severity(item.code):'RECOVERED'}: ${CODES[item.code]}\nTransition recorded ${new Date(item.created_at).toISOString()}. Last known incident; use /status for heartbeat age.\n${item.code==='uploads'?'Open Waiting Galleries on Carlo. Media remains saved pending public verification.': 'Check Booth Status and Equipment & Recovery on Carlo.'} No customer or payment details are included.`;
        try {
            await sendTelegram(env,text);
            await env.DB.prepare('UPDATE notifications SET delivered_at=?,lease_until=NULL WHERE id=? AND lease_until=?').bind(Date.now(),item.id,lease).run();
        } catch (error) {
            const delay = Math.max([60,300,900,3600,3600][Math.min(item.attempts,4)]*1000,error.retryAfter || 0);
            await env.DB.prepare('UPDATE notifications SET next_at=?,lease_until=NULL WHERE id=? AND lease_until=?').bind(time+delay,item.id,lease).run();
        }
    }
}

function timestamp(value) {
    if (typeof value!=='string' || value.length>30 || !/^\d{4}-\d\d-\d\dT/.test(value) || !Number.isFinite(Date.parse(value)) || Date.parse(value)>Date.now()+300000) throw new Error('invalid');
    return new Date(value).toISOString();
}

// Routine offline/idle pending work is not an incident. Attention or an active event with a
// ten-minute backlog is meaningful. Neither acceptance nor this count implies public delivery.
function uploadIncident(state,time=Date.now()) {
    const u=state.uploads;
    return !!u && (u.attention>0 || (state.eventState==='active' && u.pending>0 && u.oldestAt && time-Date.parse(u.oldestAt)>600000));
}
function severity(code) { return ['storage','paid_blocked'].includes(code) ? 'CRITICAL' : 'WARNING'; }

async function recordBackendHealth(env,time,available,fresh) {
    await env.DB.prepare('INSERT INTO backend_health(id,checked_at,available,reconciliation_fresh) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET checked_at=excluded.checked_at,available=excluded.available,reconciliation_fresh=excluded.reconciliation_fresh').bind('payments',time,+available,fresh==null?null:+fresh).run();
}

async function boundedJSON(request,limit) {
    if (Number(request.headers.get('content-length') || 0)>limit) throw new Error('too_large');
    const reader=request.body?.getReader();
    if (!reader) throw new Error('invalid');
    let size=0;const chunks=[];
    while (true) {
        const {done,value}=await reader.read();if(done)break;
        size+=value.byteLength;
        if(size>limit){await reader.cancel();throw new Error('too_large');}
        chunks.push(value);
    }
    const bytes=new Uint8Array(size);let offset=0;
    for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.byteLength;}
    return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
}

async function equalSecret(supplied,expected) {
    if (!expected || expected.length<32 || !supplied || supplied.length>256) return false;
    const digest=async s=>new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
    const [a,b]=await Promise.all([digest(supplied),digest(expected)]);
    return a.reduce((d,v,i)=>d|(v^b[i]),0)===0;
}

async function telegramWebhook(request,env,ctx) {
    if(!await equalSecret(request.headers.get('x-telegram-bot-api-secret-token'),env.TELEGRAM_WEBHOOK_SECRET)) return response({error:'unauthorized'},401);
    let update;
    try { update=await boundedJSON(request,4096); }
    catch(error) { return response({error:error.message==='too_large'?'too_large':'invalid_update'},error.message==='too_large'?413:422); }
    const message=update?.message;
    // Only unedited owner messages in a private chat. Ignore channel, group, callback, forwarded
    // and bot messages. Chat ID never comes from command arguments.
    if(!env.TELEGRAM_CHAT_ID || !message || message.chat?.type!=='private' || String(message.chat?.id)!==String(env.TELEGRAM_CHAT_ID)
        || String(message.from?.id)!==String(env.TELEGRAM_CHAT_ID) || message.from?.is_bot!==false
        || message.forward_origin || message.forward_from || message.sender_chat) return response({error:'forbidden'},403);
    if(!Number.isSafeInteger(update.update_id) || update.update_id<0 || !Number.isSafeInteger(message.date)
        || Date.now()-message.date*1000>86400000 || message.date*1000-Date.now()>300000 || typeof message.text!=='string' || message.text.length>128) return response({error:'invalid_update'},422);
    const match=/^\/(status|event|uploads|incidents|help)(?:@[a-zA-Z0-9_]{5,32})?$/.exec(message.text.trim());
    if(!match) return response({ignored:true});
    const existing=await env.DB.prepare('SELECT update_id FROM telegram_commands WHERE update_id=?').bind(update.update_id).first();
    if(existing) return response({duplicate:true});
    const time=Date.now(),window=Math.floor(time/60000);
    const reply=await ownerReply(env,match[1],time);
    // Atomic D1 batch bounds concurrent requests to ten owner commands/minute. One durable
    // reply per update; duplicate deliveries cannot authorize or execute any booth operation.
    const results=await env.DB.batch([
        env.DB.prepare('INSERT INTO telegram_rate(window,count) VALUES(?,1) ON CONFLICT(window) DO UPDATE SET count=count+1 WHERE count<11').bind(window),
        env.DB.prepare('INSERT OR IGNORE INTO telegram_commands(update_id,created_at,reply_text,next_at) SELECT ?,?,?,? WHERE (SELECT count FROM telegram_rate WHERE window=?)<=10').bind(update.update_id,time,reply,time,window)
    ]);
    if(results[1].meta.changes!==1) {
        const duplicate=await env.DB.prepare('SELECT update_id FROM telegram_commands WHERE update_id=?').bind(update.update_id).first();
        return duplicate?response({duplicate:true}):response({error:'rate_limited'},429);
    }
    ctx.waitUntil(deliverCommands(env,time));
    return response({accepted:true});
}

export async function ownerReply(env,command,time=Date.now()) {
    if(command==='help') return 'Made to Keep Studios · owner monitor (read only)\n/status — last reported booth, heartbeat, network, printer and payment health\n/event — last reported event state and activity\n/uploads — unverified queue and operator attention\n/incidents — unresolved last-known incidents\n/help — commands\nNo printing, payment, event changes, deletion or credentials can be requested.';
    const device=await env.DB.prepare('SELECT last_seen,state_json FROM devices WHERE id=?').bind('carlo').first();
    const state=device?JSON.parse(device.state_json):null;
    const stale=!device || time-device.last_seen>=Number(env.STALE_SECONDS || 900)*1000
        || (state?.reportedAt && time-Date.parse(state.reportedAt)>=Number(env.STALE_SECONDS || 900)*1000);
    const intro=`Made to Keep Studios · Carlo\nReport generated ${new Date(time).toISOString()} (not live)\n${stale?'STALE / unavailable':'Fresh at report time'} · last heartbeat: ${device?new Date(device.last_seen).toISOString():'never received'}\nDevice sample time: ${state?.reportedAt || 'not reported by this app version'}\n`;
    if(command==='incidents') {
        const incidents=(await env.DB.prepare('SELECT code,active,changed_at FROM incidents WHERE active=1 ORDER BY changed_at DESC LIMIT 20').all()).results || [];
        return intro+(incidents.length?incidents.map(i=>`${severity(i.code)} · ${CODES[i.code] || 'Unknown incident'} · transition ${new Date(i.changed_at).toISOString()} · operator attention required (last known)`).join('\n'):'No unresolved incidents recorded. This does not prove current equipment readiness.');
    }
    if(!state) return intro+'Device telemetry unavailable. No booth state is assumed.';
    if(command==='uploads') {
        const u=state.uploads;
        return intro+(u?`Last reported unverified queue: ${u.pending}\nUploading: ${u.uploading} · Verifying: ${u.verifying}\nNeeds attention: ${u.attention}\nLast upload activity: ${u.activityAt || 'not reported'}\nOldest saved item: ${u.oldestAt || 'not reported'}\nPending media is retained on iPad. Only public verification establishes availability.`:'Upload metrics not reported by this app version.');
    }
    const event=`Last reported event: ${state.eventReference || 'none reported'}\nEvent state: ${state.eventState || 'not reported'}\nLast observed guest activity: ${state.activityAt || 'not reported'}`;
    if(command==='event') return intro+event;
    const health=await env.DB.prepare('SELECT checked_at,available,reconciliation_fresh FROM backend_health WHERE id=?').bind('payments').first();
    const backend=health?`${health.available?'available':'unavailable'} at ${new Date(health.checked_at).toISOString()}${time-health.checked_at>=Number(env.STALE_SECONDS || 900)*1000?' (STALE)':''}`:'not independently checked';
    return intro+`Last reported booth: ${state.mode}\nNetwork path: ${state.network} (does not prove internet reachability)\nPrinter: ${state.printer} (last reported; physical output unverified)\nDevice payment state: ${state.payment}\nPayment backend: ${backend}\nStorage: ${state.storage}\n`+event;
}

async function deliverCommands(env,time=Date.now()) {
    if(!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) return;
    const due=(await env.DB.prepare('SELECT * FROM telegram_commands WHERE delivered_at IS NULL AND attempts<5 AND next_at<=? AND (lease_until IS NULL OR lease_until<=?) ORDER BY created_at LIMIT 3').bind(time,time).all()).results || [];
    for(const item of due) {
        const lease=time+30000;
        const claim=await env.DB.prepare('UPDATE telegram_commands SET lease_until=?,attempts=attempts+1 WHERE update_id=? AND delivered_at IS NULL AND attempts=? AND (lease_until IS NULL OR lease_until<=?)').bind(lease,item.update_id,item.attempts,time).run();
        if(claim.meta.changes!==1) continue;
        try {
            await sendTelegram(env,item.reply_text);
            await env.DB.prepare('UPDATE telegram_commands SET delivered_at=?,lease_until=NULL WHERE update_id=? AND lease_until=?').bind(Date.now(),item.update_id,lease).run();
        } catch (error) {
            const delay=Math.max([60,300,900,3600,3600][Math.min(item.attempts,4)]*1000,error.retryAfter || 0);
            await env.DB.prepare('UPDATE telegram_commands SET next_at=?,lease_until=NULL WHERE update_id=? AND lease_until=?').bind(time+delay,item.update_id,lease).run();
        }
    }
}

async function sendTelegram(env,text) {
    const r=await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({chat_id:env.TELEGRAM_CHAT_ID,text,protect_content:true}),signal:AbortSignal.timeout(8000)});
    const result=await r.json();
    if(!r.ok || !result.ok) {
        const error=new Error('delivery');
        if(r.status===429 && Number.isFinite(result.parameters?.retry_after)) error.retryAfter=Math.min(86400,Math.max(0,result.parameters.retry_after))*1000;
        throw error;
    }
}
