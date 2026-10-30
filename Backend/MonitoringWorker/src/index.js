const HEADERS = { 'content-type': 'application/json', 'cache-control': 'no-store' };
const RELEASE = 'monitoring-v3-2026-10-30';
const CODES = {
    offline: 'Carlo heartbeat missing', backend: 'Payment backend unavailable', verification: 'Payment confirmation repeatedly failing',
    review: 'Payment requires owner review', paid_blocked: 'Verified payment waiting before camera', printer: 'Printer readiness needs attention',
    uncertain_print: 'Physical print outcome uncertain', printer_attention: 'Printer needs attention',
    storage: 'Critical local storage issue', paused: 'Booth paused or event recovery required',
    reconciliation: 'Backend reconciliation stale', uploads: 'Gallery delivery needs attention', camera: 'Camera needs attention'
};
const VALID = { mode: ['regular','event','paused','recovery'], network: ['online','offline','unknown'], payment: ['ready','unavailable','review'], printer: ['ready','recovery','uncertain','unavailable'], storage: ['ready','error'] };
const PRINTER = {transport:['bluetooth','wifi','auto','unknown'],connection:['connected','disconnected','connecting','unknown'],readiness:['ready','busy','diagnostic_required','recovery_required','unavailable','unknown'],evidence:['clear','unresolved','unknown']};
const CAMERA = ['ready','initializing','unavailable','permission_denied','interrupted','recovery_required','unknown'];
const GUEST = ['idle','guest_in_progress','capture_waiting','printing','recovery_required','unknown'];
const DEVICE_CODES = ['verification','review','paid_blocked','storage','paused'];
const response = (v, status = 200) => new Response(JSON.stringify(v), {status, headers: HEADERS});
const threshold = (env,state) => state?.eventState==='active' ? 600000 : Number(env.STALE_SECONDS || 900)*1000;
const fresh = (env,device,state,time) => !!device && time-device.last_seen<threshold(env,state)
    && (!state?.reportedAt || time-Date.parse(state.reportedAt)<threshold(env,state));
const pht = time => new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Manila',dateStyle:'medium',timeStyle:'short'}).format(new Date(time))+' PHT';

export default {
    async fetch(request, env, ctx) {
        try {
            const path = new URL(request.url).pathname;
            if (path === '/v1/telegram' && request.method === 'POST') return await telegramWebhook(request,env,ctx);
            if (path === '/health' && request.method === 'GET') return response({service:'made-to-keep-monitor',version:3,telemetryVersion:3,release:RELEASE});
            if (path === '/v1/heartbeat' && request.method === 'POST') {
                if (!await authorized(request, env.DEVICE_TOKEN)) return response({error:'unauthorized'},401);
                let state;
                try { state = validate(await boundedJSON(request,2048)); }
                catch (error) { return response({error:error.message==='too_large'?'too_large':'invalid_telemetry'},error.message==='too_large'?413:422); }
                const time = Date.now(), lock = await claimLock(env,'state',time);
                if (!lock) return response({error:'monitor_busy'},503);
                try {
                    const previous = await env.DB.prepare('SELECT last_seen,state_json FROM devices WHERE id=?').bind('carlo').first();
                    if (previous && time-previous.last_seen<30000) return response({error:'rate_limited'},429);
                    const prior = previous && JSON.parse(previous.state_json);
                    if (prior?.reportedAt && state.reportedAt && Date.parse(state.reportedAt)<Date.parse(prior.reportedAt))
                        return response({accepted:false,reason:'older_sample'},200);
                    await observeDevice(env,state,time,lock);
                } finally { await releaseLock(env,'state',lock); }
                ctx.waitUntil(deliver(env,time));
                return response({accepted:true,serverTime:new Date(time).toISOString()});
            }
            if (!await authorized(request, env.OWNER_READ_TOKEN)) return response({error:'unauthorized'},401);
            if (path === '/v1/overview' && request.method === 'GET') {
                const device = await env.DB.prepare('SELECT last_seen,state_json FROM devices WHERE id=?').bind('carlo').first();
                const state = device && JSON.parse(device.state_json);
                const incidents = (await env.DB.prepare('SELECT code,active,changed_at FROM incidents WHERE active=1').all()).results;
                const observations = (await env.DB.prepare('SELECT * FROM monitoring_observations').all()).results;
                const episodes = (await env.DB.prepare('SELECT * FROM notification_episodes').all()).results;
                const delivery = await env.DB.prepare('SELECT COUNT(*) pending,COALESCE(SUM(CASE WHEN attempts>=5 THEN 1 ELSE 0 END),0) failed FROM (SELECT attempts,delivered_at,superseded_at FROM notifications UNION ALL SELECT attempts,delivered_at,superseded_at FROM v3_notifications) WHERE delivered_at IS NULL AND superseded_at IS NULL').first();
                const commands = await env.DB.prepare('SELECT COUNT(*) pending,COALESCE(SUM(CASE WHEN attempts>=5 THEN 1 ELSE 0 END),0) failed FROM telegram_commands WHERE delivered_at IS NULL').first();
                return response({device:'Carlo',online:fresh(env,device,state,Date.now()),lastHeartbeat:device?.last_seen || null,state,incidents,observations,episodes,delivery,commands,release:RELEASE});
            }
            if (path === '/v1/test-notification' && request.method === 'POST') {
                const time=Date.now(),key='owner-test-'+Math.floor(time/3600000);
                await env.DB.prepare('INSERT OR IGNORE INTO notifications(id,code,active,created_at,next_at) VALUES(?,?,?,?,?)').bind(key,'owner_test',1,time,time).run();
                await deliver(env,time);
                return response({queued:true});
            }
            return response({error:'not_found'},404);
        } catch { return response({error:'monitor_unavailable'},503); }
    },
    async scheduled(controller,env,ctx) { ctx.waitUntil(check(env,controller.scheduledTime)); }
};

export function validate(value) {
    if (!value || typeof value!=='object' || Array.isArray(value) || Object.keys(value).some(k=>![...Object.keys(VALID),'incidents','eventReference','reportedAt','eventState','activityAt','uploads','telemetryVersion','printerObservation','camera','guest'].includes(k))) throw new Error('invalid');
    const clean = {};
    for (const [key,values] of Object.entries(VALID)) {
        if (!values.includes(value[key])) throw new Error('invalid');
        clean[key] = value[key];
    }
    if (!Array.isArray(value.incidents) || value.incidents.length>10 || value.incidents.some(code=>typeof code!=='string' || ![...DEVICE_CODES,'printer','uncertain_print'].includes(code))) throw new Error('invalid');
    clean.incidents = [...new Set(value.incidents)].sort();
    if (value.eventReference != null && (typeof value.eventReference!=='string' || !/^[a-zA-Z0-9-]{1,40}$/.test(value.eventReference))) throw new Error('invalid');
    clean.eventReference = value.eventReference || null;
    if (value.reportedAt != null) clean.reportedAt = timestamp(value.reportedAt);
    if (value.activityAt != null) clean.activityAt = timestamp(value.activityAt);
    if (value.eventState != null) {
        if (![...['active','paused','idle','recovery'],...(value.telemetryVersion===3?['unknown']:[])].includes(value.eventState)) throw new Error('invalid');
        clean.eventState = value.eventState;
    }
    if (value.telemetryVersion != null && value.telemetryVersion!==3) throw new Error('invalid');
    if (value.telemetryVersion===3) {
        if (!clean.reportedAt) throw new Error('invalid');
        clean.telemetryVersion=3;
        if (value.printerObservation!=null) {
            const p=value.printerObservation;
            if (typeof p!=='object' || Array.isArray(p) || Object.keys(p).some(k=>!Object.hasOwn(PRINTER,k))) throw new Error('invalid');
            clean.printerObservation={};
            for (const [key,allowed] of Object.entries(PRINTER)) {
                if (!allowed.includes(p[key])) throw new Error('invalid');
                clean.printerObservation[key]=p[key];
            }
        }
        for (const [key,allowed] of [['camera',CAMERA],['guest',GUEST]]) if(value[key]!=null) {
            if(!allowed.includes(value[key])) throw new Error('invalid');
            clean[key]=value[key];
        }
    } else if (['printerObservation','camera','guest'].some(k=>value[k]!=null)) throw new Error('invalid');
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

async function claimLock(env,id,time) {
    const owner=crypto.randomUUID();
    const result=await env.DB.prepare('INSERT INTO monitoring_locks(id,owner,expires_at) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET owner=excluded.owner,expires_at=excluded.expires_at WHERE expires_at<=?').bind(id,owner,time+30000,time).run();
    return result.meta.changes===1?owner:null;
}
async function releaseLock(env,id,owner) { await env.DB.prepare('DELETE FROM monitoring_locks WHERE id=? AND owner=?').bind(id,owner).run(); }

async function observeDevice(env,state,time,lock) {
    const isFresh=fresh(env,{last_seen:time},state,time),version=state.telemetryVersion || (state.reportedAt || state.uploads || state.eventState?2:1);
    const states=Object.fromEntries(DEVICE_CODES.map(c=>[c,!isFresh?null:(state.incidents.includes(c)?true:(c!=='storage' && state.storage==='error'?null:false))]));
    states.offline=isFresh?false:null;
    states.uploads=isFresh?uploadIncident(state,time):null;
    if (version===3) {
        const p=state.printerObservation;
        states.printer=!isFresh || !p || p.readiness==='unknown'?null:['unavailable','diagnostic_required','recovery_required'].includes(p.readiness);
        if (isFresh && p?.connection==='connecting' && p.readiness!=='recovery_required') states.printer=true;
        states.uncertain_print=!isFresh || !p || p.evidence==='unknown'?null:p.evidence==='unresolved';
        states.camera=!isFresh || !state.camera || ['unknown','initializing'].includes(state.camera)?null:
            (['permission_denied','unavailable','interrupted','recovery_required'].includes(state.camera)?true:false);
    } else {
        states.printer=isFresh?state.incidents.includes('printer'):null;
        states.uncertain_print=isFresh?state.incidents.includes('uncertain_print'):null;
        states.camera=null;
    }
    const deviceWrite=env.DB.prepare('INSERT INTO devices(id,last_seen,state_json) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen,state_json=excluded.state_json').bind('carlo',time,JSON.stringify(state));
    await syncIncidents(env,states,time,version,state,lock,[deviceWrite]);
}

// One bounded read batch and one atomic write batch. The durable state lease serializes
// heartbeat/Cron across isolates; no in-memory suppression owns an incident episode.
export async function syncIncidents(env,states,time=Date.now(),version=3,state={},lock=null,additionalWrites=[]) {
    const records=await env.DB.batch([
        env.DB.prepare('SELECT * FROM monitoring_observations'),
        env.DB.prepare('SELECT * FROM incidents'),
        env.DB.prepare('SELECT * FROM notification_episodes')
    ]);
    const observations=new Map(records[0].results.map(r=>[r.code,r]));
    const incidents=new Map(records[1].results.map(r=>[r.code,r]));
    const episodes=new Map(records[2].results.map(r=>[r.code,r]));
    // Bridge existing V2 printer evidence without deleting either underlying incident.
    const previousComponents=(incidents.get('printer')?.active?1:0)|(incidents.get('uncertain_print')?.active?2:0);
    if(previousComponents && !observations.has('printer') && !observations.has('uncertain_print') && !episodes.has('printer_attention')) episodes.set('printer_attention',
        {active:1,components:previousComponents,severity:'WARNING',revision:0});
    const writes=[];
    const updateEpisode=(code,active,components,priority)=>{
        const old=episodes.get(code);
        if(!old && !active) return;
        if(!active) components=old?.components || components;
        const transition=!old || old.revision===0 || old.active!==+active || (active && ((components & ~old.components)!==0 || (priority==='CRITICAL' && old.severity!=='CRITICAL')));
        if(!transition) {
            writes.push(env.DB.prepare('UPDATE notification_episodes SET observed_at=?,components=?,severity=? WHERE code=?').bind(time,components,priority,code));
            return;
        }
        const revision=(old?.revision || 0)+1;
        const table=['printer_attention','camera'].includes(code)?'v3_notifications':'notifications';
        writes.push(
            env.DB.prepare('INSERT INTO notification_episodes(code,active,severity,components,revision,changed_at,observed_at) VALUES(?,?,?,?,?,?,?) ON CONFLICT(code) DO UPDATE SET active=excluded.active,severity=excluded.severity,components=excluded.components,revision=excluded.revision,changed_at=excluded.changed_at,observed_at=excluded.observed_at')
                .bind(code,+active,priority,components,revision,time,time),
            env.DB.prepare(`UPDATE ${table} SET superseded_at=? WHERE code=? AND delivered_at IS NULL AND superseded_at IS NULL AND (lease_until IS NULL OR lease_until<=?)`).bind(time,code,time),
            env.DB.prepare(`INSERT INTO ${table}(id,code,active,created_at,next_at,episode_revision) VALUES(?,?,?,?,?,?)`).bind(`v3:${code}:${revision}`,code,+active,time,time,revision)
        );
    };
    for(const [code,input] of Object.entries(states)) {
        if(!Object.hasOwn(CODES,code) || code==='printer_attention') continue;
        const observation=observations.get(code);
        if(observation && observation.observed_at>time) continue;
        const capabilityVersion=['printer','uncertain_print','camera'].includes(code)?version:(code==='uploads'?2:1);
        const active=input===false && observation?.source_version>capabilityVersion?null:input;
        const since=active===true?(observation?.value===1 && time-observation.observed_at<900000?observation.unhealthy_since:time):null;
        observations.set(code,{value:active==null?null:+active,observed_at:time,unhealthy_since:since});
        writes.push(env.DB.prepare('INSERT INTO monitoring_observations(code,value,observed_at,source_version,unhealthy_since) VALUES(?,?,?,?,?) ON CONFLICT(code) DO UPDATE SET value=excluded.value,observed_at=excluded.observed_at,source_version=MAX(source_version,excluded.source_version),unhealthy_since=excluded.unhealthy_since')
            .bind(code,active==null?null:+active,time,capabilityVersion,since));
        if(active==null) continue;
        const old=incidents.get(code);
        if(old?.active!==+active && (old || active)) {
            writes.push(
                env.DB.prepare('INSERT INTO incident_history(code,active,changed_at) VALUES(?,?,?)').bind(code,+active,time),
                env.DB.prepare('INSERT INTO incidents(code,active,changed_at) VALUES(?,?,?) ON CONFLICT(code) DO UPDATE SET active=excluded.active,changed_at=excluded.changed_at').bind(code,+active,time)
            );
            incidents.set(code,{code,active:+active,changed_at:time});
        }
        if(!['printer','uncertain_print'].includes(code)) {
            if(code==='camera' && active && state.eventState!=='active') continue;
            updateEpisode(code,active,1,severity(code));
        }
    }
    if(Object.hasOwn(states,'printer') || Object.hasOwn(states,'uncertain_print')) {
        const printer=incidents.get('printer'),uncertain=incidents.get('uncertain_print');
        const po=observations.get('printer'),uo=observations.get('uncertain_print');
        const components=(printer?.active?1:0)|(uncertain?.active?2:0);
        const recovery=state.printerObservation?.readiness==='recovery_required';
        const guestNeedsAttention=state.eventState==='active' && state.guest==='recovery_required' && po?.value===1;
        const legacyUrgent=state.telemetryVersion!==3 && po?.value===1 &&
            (!state.eventState || state.eventState==='unknown' || ['recovery','uncertain'].includes(state.printer));
        const eligible=!!uncertain?.active || recovery || guestNeedsAttention || legacyUrgent ||
            (po?.value===1 && state.eventState==='active' && time-po.unhealthy_since>=90000);
        const existing=episodes.get('printer_attention');
        if((eligible || !components || existing?.active) && (components || (((existing?.components || 0)&1 ? po?.value===0 : true) && ((existing?.components || 0)&2 ? uo?.value===0 : true)))) {
            const priority=recovery || (uncertain?.active && state.eventState==='active' && ['printing','recovery_required'].includes(state.guest))?'CRITICAL':
                (existing?.active && (po?.value==null || uo?.value==null)?existing.severity:'WARNING');
            updateEpisode('printer_attention',!!components,components,priority);
        }
    }
    if(writes.length || additionalWrites.length) await env.DB.batch([...additionalWrites,...(lock?[stateGuard(env,lock)]:[]),...writes]);
}

export async function check(env,time=Date.now()) {
    const lock=await claimLock(env,'state',Date.now());
    if(lock) try {
        const device=await env.DB.prepare('SELECT last_seen,state_json FROM devices WHERE id=?').bind('carlo').first();
        if(device) {
            const state=JSON.parse(device.state_json);
            // Cron can establish lost contact, never equipment recovery or restored contact.
            if(!fresh(env,device,state,time)) await syncIncidents(env,{offline:true},time,3,state,lock);
        }
        if(env.PAYMENTS_HEALTH_URL) {
            try {
                const r=await fetch(env.PAYMENTS_HEALTH_URL,{headers:{authorization:'Bearer '+env.PAYMENTS_HEALTH_TOKEN},signal:AbortSignal.timeout(8000)});
                if(!r.ok) throw new Error('unavailable');
                const h=await r.json();
                if(h.environment!=='live' || h.liveEnabled!==true || typeof h.reconciliationFresh!=='boolean') throw new Error('wrong_environment');
                await recordBackendHealth(env,time,true,h.reconciliationFresh,lock);
                await syncIncidents(env,{backend:false,reconciliation:!h.reconciliationFresh},time,3,{},lock);
            } catch { await recordBackendHealth(env,time,false,null,lock); await syncIncidents(env,{backend:true,reconciliation:null},time,3,{},lock); }
        }
    } finally { await releaseLock(env,'state',lock); }
    await deliver(env,time,2);
    await deliverCommands(env,time,2);
    // Retain exhausted replies; the old 7-day unconditional delete erased failed evidence.
    await env.DB.batch([
        env.DB.prepare('DELETE FROM telegram_rate WHERE window<?').bind(Math.floor(time/60000)-1440),
        env.DB.prepare('DELETE FROM telegram_commands WHERE created_at<? AND delivered_at IS NOT NULL').bind(time-7*86400000),
        ...['notifications','v3_notifications'].map(table=>env.DB.prepare(`DELETE FROM ${table} WHERE (delivered_at IS NOT NULL OR superseded_at IS NOT NULL) AND created_at<?`).bind(time-30*86400000))
    ]);
}

export async function deliver(env,time=Date.now(),limit=3) {
    if(!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) return;
    // Supersede every obsolete row before selecting the bounded priority queue, including V2
    // printer streams replaced by one episode. History stays distinct from delivery success.
    await env.DB.prepare(`UPDATE notifications SET superseded_at=? WHERE delivered_at IS NULL AND superseded_at IS NULL
        AND (lease_until IS NULL OR lease_until<=?) AND ((code IN ('printer','uncertain_print') AND EXISTS(SELECT 1 FROM notification_episodes WHERE code='printer_attention')) OR
        (episode_revision IS NOT NULL AND episode_revision<>COALESCE((SELECT revision FROM notification_episodes e WHERE e.code=notifications.code),-1)) OR
        (episode_revision IS NULL AND EXISTS(SELECT 1 FROM notification_episodes e WHERE e.code=notifications.code)) OR
        (episode_revision IS NULL AND code<>'owner_test' AND active<>COALESCE((SELECT active FROM incidents i WHERE i.code=notifications.code),-1)))`).bind(time,time).run();
    await env.DB.prepare(`UPDATE v3_notifications SET superseded_at=? WHERE delivered_at IS NULL AND superseded_at IS NULL
        AND (lease_until IS NULL OR lease_until<=?) AND episode_revision<>COALESCE((SELECT revision FROM notification_episodes WHERE code=v3_notifications.code),-1)`).bind(time,time).run();
    const due=(await env.DB.prepare(`SELECT n.* FROM (SELECT *, 'notifications' AS source FROM notifications UNION ALL SELECT *, 'v3_notifications' AS source FROM v3_notifications) n LEFT JOIN notification_episodes e ON e.code=n.code
        WHERE n.delivered_at IS NULL AND n.superseded_at IS NULL AND n.attempts<5 AND n.next_at<=?
        AND (n.lease_until IS NULL OR n.lease_until<=?)
        ORDER BY CASE WHEN n.active=1 AND e.severity='CRITICAL' THEN 0 WHEN n.active=0 THEN 1 ELSE 2 END,n.created_at LIMIT 6`).bind(time,time).all()).results || [];
    let sends=0;
    for(const item of due) {
        if(sends>=limit) break;
        const lock=await claimLock(env,'delivery:'+item.code,Date.now());
        if(!lock) continue;
        try {
            const snapshot=await env.DB.batch([
                env.DB.prepare('SELECT * FROM notification_episodes WHERE code=?').bind(item.code),
                env.DB.prepare('SELECT active,delivered_at FROM notifications WHERE code=? AND delivered_at IS NOT NULL UNION ALL SELECT active,delivered_at FROM v3_notifications WHERE code=? AND delivered_at IS NOT NULL ORDER BY delivered_at DESC LIMIT 1').bind(item.code,item.code),
                env.DB.prepare('SELECT last_seen,state_json FROM devices WHERE id=?').bind('carlo'),
                env.DB.prepare('SELECT code,value,observed_at FROM monitoring_observations')
            ]);
            const current=snapshot[0].results[0],sent=snapshot[1].results[0],device=snapshot[2].results[0];
            const state=device && JSON.parse(device.state_json);
            // source is a fixed SQL literal from the UNION, never request input.
            const table=item.source==='v3_notifications'?'v3_notifications':'notifications';
            const priorPrinter=item.code==='printer_attention' && !sent ? (await env.DB.prepare("SELECT n.active FROM notifications n WHERE n.code IN ('printer','uncertain_print') AND n.delivered_at IS NOT NULL AND n.active=1 AND NOT EXISTS(SELECT 1 FROM notifications newer WHERE newer.code=n.code AND newer.delivered_at>n.delivered_at) LIMIT 1").first()) : null;
            if(item.code!=='owner_test' && ((item.episode_revision!=null && current?.revision!==item.episode_revision) || (!item.active && !(sent || priorPrinter)?.active))) {
                await env.DB.prepare(`UPDATE ${table} SET superseded_at=? WHERE id=? AND delivered_at IS NULL`).bind(time,item.id).run();continue;
            }
            const requiresDevice=!['owner_test','backend','reconciliation'].includes(item.code) && !(item.code==='offline' && item.active);
            const known=item.code==='owner_test' || episodeKnown(snapshot[3].results,item.code,item.active,current?.components,time);
            if(!known || (requiresDevice && !fresh(env,device,state,time))) {
                await env.DB.prepare(`UPDATE ${table} SET next_at=? WHERE id=?`).bind(time+300000,item.id).run();continue;
            }
            const lease=Date.now()+30000;
            const claim=await env.DB.prepare(`UPDATE ${table} SET lease_until=?,attempts=attempts+1 WHERE id=? AND delivered_at IS NULL AND superseded_at IS NULL AND attempts=? AND (lease_until IS NULL OR lease_until<=?)`).bind(lease,item.id,item.attempts,Date.now()).run();
            if(claim.meta.changes!==1) continue;
            sends++;
            try {
                await sendTelegram(env,notificationText(item,current,state,device,time,snapshot[3].results));
                await env.DB.prepare(`UPDATE ${table} SET delivered_at=?,lease_until=NULL WHERE id=? AND lease_until=?`).bind(Date.now(),item.id,lease).run();
            } catch(error) {
                const delay=Math.max([60,300,900,3600,3600][Math.min(item.attempts,4)]*1000,error.retryAfter || 0);
                await env.DB.prepare(`UPDATE ${table} SET next_at=?,lease_until=NULL WHERE id=? AND lease_until=?`).bind(time+delay,item.id,lease).run();
            }
        } finally { await releaseLock(env,'delivery:'+item.code,lock); }
    }
}

function episodeKnown(observations,code,active,components,time) {
    const codes=code==='printer_attention'?['printer','uncertain_print'].filter((_,i)=>active || !components || (components & (1<<i))):[code];
    const rows=codes.map(c=>observations.find(r=>r.code===c));
    return active?rows.some(r=>r?.value===1 && time-r.observed_at<900000):rows.every(r=>r?.value===0 && time-r.observed_at<900000);
}
function action(code) {
    if(['printer','uncertain_print','printer_attention'].includes(code)) return 'Open Equipment & Recovery on Carlo. Inspect the original receipt before deciding whether to reprint.';
    if(code==='uploads') return 'Open Waiting Galleries on Carlo. Media remains saved pending public verification.';
    if(code==='offline') return 'Check Carlo is foregrounded and has network access. Missing contact does not diagnose equipment failure.';
    if(code==='camera') return 'Check the camera on Carlo; use existing local recovery. Monitoring does not restart capture.';
    if(code==='storage') return 'Pause admission locally and inspect storage/recovery on Carlo. Preserve original records.';
    return 'Check Booth Status and local recovery on Carlo.';
}
function printerText(state) {
    const p=state?.printerObservation;
    return p?`Printer connection: ${p.connection} (${p.transport})\nReadiness: ${p.readiness}\nPhysical-print evidence: ${p.evidence==='unresolved'?'requires review':p.evidence==='clear'?'no unresolved evidence; output NOT VERIFIED':'UNKNOWN'}`:
        `Printer: ${state?.printer || 'unknown'} (legacy observation; physical output NOT VERIFIED)`;
}
function notificationText(item,current,state,device,time,observations) {
    if(item.code==='owner_test') return 'Made to Keep Studios · monitoring test. Owner alerts are connected. No payment or printing was performed.';
    const level=item.active?(current?.severity || severity(item.code)):'RECOVERED';
    let detail='';
    if(item.code==='printer_attention') {
        const impact=!item.active?'Reported printer conditions cleared. Physical output remains NOT VERIFIED.':
            (current.components&2)?'Physical print outcome uncertain. A previous receipt may or may not have printed.':
            state?.printerObservation?.readiness==='diagnostic_required'?'A diagnostic is required; mechanical failure is not established.':
            state?.printerObservation?.readiness==='recovery_required'?'Local printer recovery is required; physical output NOT VERIFIED.':
            'Receipt printing may be delayed; selected transport readiness is not established.';
        detail=printerText(state)+'\n'+impact;
    }
    if(item.code==='offline') detail=item.active?'Monitoring contact overdue. Current device/equipment state UNKNOWN.':
        'Monitoring contact was restored. Latest reported status: '+(state?.reportedAt || 'sample time not reported')+'. Equipment readiness is only known where explicitly reported; physical output NOT VERIFIED.';
    const observed=observations.filter(o=>item.code==='printer_attention'?['printer','uncertain_print'].includes(o.code):o.code===item.code);
    return `Made to Keep Studios · Carlo\n${level}: ${CODES[item.code]}\nEvent: ${state?.eventState || 'unknown'} (last reported)\nTransition: ${pht(item.created_at)}\nCondition observed: ${observed.length?pht(Math.max(...observed.map(o=>o.observed_at))):'unknown'}\n${detail}\n${action(item.code)}\nLast device report: ${device?pht(device.last_seen):'never received'}; sample: ${state?.reportedAt || 'not reported'}. Report generated ${pht(time)}.`;
}

function timestamp(value) {
    if(typeof value!=='string' || value.length>30 || !/^\d{4}-\d\d-\d\dT/.test(value) || !Number.isFinite(Date.parse(value)) || Date.parse(value)>Date.now()+300000) throw new Error('invalid');
    return new Date(value).toISOString();
}
function uploadIncident(state,time) {
    const u=state.uploads;
    if(!u) return null;
    if(u.attention>0) return true;
    if(u.pending===0) return false;
    if(!state.eventState || !u.oldestAt) return null;
    return state.eventState==='active' && time-Date.parse(u.oldestAt)>600000;
}
function severity(code) { return ['storage','paid_blocked'].includes(code)?'CRITICAL':'WARNING'; }
// The NOT NULL constraint aborts the entire batch if ownership was lost, including after
// a stalled invocation outlives its lease. A late writer cannot overwrite a newer observation.
function stateGuard(env,owner) {
    return env.DB.prepare(`INSERT INTO monitoring_locks(id,owner,expires_at)
        VALUES('state',?,(SELECT CASE WHEN owner=? THEN ? ELSE NULL END FROM monitoring_locks WHERE id='state'))
        ON CONFLICT(id) DO UPDATE SET expires_at=excluded.expires_at`).bind(owner,owner,Date.now()+30000);
}
async function recordBackendHealth(env,time,available,fresh,lock) {
    await env.DB.batch([stateGuard(env,lock),env.DB.prepare('INSERT INTO backend_health(id,checked_at,available,reconciliation_fresh) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET checked_at=excluded.checked_at,available=excluded.available,reconciliation_fresh=excluded.reconciliation_fresh').bind('payments',time,+available,fresh==null?null:+fresh)]);
}

async function authorized(request,secret) {
    if (!secret || secret.length<32) return false;
    const supplied = request.headers.get('authorization') || '';
    if (supplied.length>600) return false;
    const hash = async s => new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
    const [a,b] = await Promise.all([hash(supplied),hash('Bearer '+secret)]);
    return a.reduce((diff,v,i)=>diff | (v^b[i]),0)===0;
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
    if(update?.edited_message || update?.edited_channel_post || !env.TELEGRAM_CHAT_ID || !message || message.chat?.type!=='private' || String(message.chat?.id)!==String(env.TELEGRAM_CHAT_ID)
        || String(message.from?.id)!==String(env.TELEGRAM_CHAT_ID) || message.from?.is_bot!==false
        || ['forward_origin','forward_from','forward_from_chat','forward_sender_name','forward_signature','forward_date','is_automatic_forward'].some(k=>message[k]!=null) || message.sender_chat) return response({error:'forbidden'},403);
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
    if(command==='help') return 'Made to Keep Studios · owner monitor (read only)\n/status — last reported booth, contact, printer dimensions, camera, guest and payment health\n/event — last reported event state and activity\n/uploads — unverified queue and operator attention\n/incidents — correlated unresolved last-known incidents and actions\n/help — commands\nNo printing, payment, event changes, deletion, recovery acknowledgment or credentials can be requested.';
    const device=await env.DB.prepare('SELECT last_seen,state_json FROM devices WHERE id=?').bind('carlo').first();
    const state=device?JSON.parse(device.state_json):null;
    const stale=!fresh(env,device,state,time);
    const intro=`Made to Keep Studios · Carlo\nReport generated ${pht(time)} (not live)\n${stale?'STALE / unavailable':'Fresh at report time'} · last heartbeat: ${device?new Date(device.last_seen).toISOString():'never received'}\nDevice sample time: ${state?.reportedAt || 'not reported by this app version'}\n`;
    const incidents=(await env.DB.prepare('SELECT code,active,changed_at FROM incidents WHERE active=1 ORDER BY changed_at DESC LIMIT 20').all()).results || [];
    const observations=(await env.DB.prepare('SELECT code,value,observed_at FROM monitoring_observations').all()).results || [];
    const printerEpisode=await env.DB.prepare("SELECT * FROM notification_episodes WHERE code='printer_attention'").first();
    if(command==='incidents') {
        const printer=incidents.filter(i=>['printer','uncertain_print'].includes(i.code));
        const other=incidents.filter(i=>!['printer','uncertain_print'].includes(i.code));
        let text=other.map(i=>{
            const o=observations.find(o=>o.code===i.code);
            return `${severity(i.code)} · ${CODES[i.code]} · transition ${pht(i.changed_at)} · ${stale || o?.value==null?'current evidence UNKNOWN; last known':'reported unresolved'}\n${action(i.code)}`;
        }).join('\n');
        if(printer.length || printerEpisode?.active) {
            const ep=printerEpisode;
            const unknown=stale || ['printer','uncertain_print'].some(c=>observations.find(o=>o.code===c)?.value==null);
            text+=`\n${ep?.active?ep.severity:'INFORMATIONAL'} · Printer needs attention · transition ${pht(printer.length?Math.min(...printer.map(i=>i.changed_at)):ep.changed_at)} · ${unknown?'current evidence UNKNOWN; last known':'reported unresolved'}\nLast-known conditions: ${printer.length?printer.map(i=>CODES[i.code]).join('; '):'Outstanding printer episode; current component evidence unavailable'}\n${printerText(state)}\n${action('printer_attention')}`;
        }
        return intro+(text || 'No unresolved incidents recorded. This does not prove current equipment readiness.');
    }
    if(!state) return intro+'Device telemetry unavailable. No booth state is assumed.';
    if(command==='uploads') {
        const u=state.uploads;
        return intro+(u?`Last reported unverified queue: ${u.pending}\nUploading: ${u.uploading} · Verifying: ${u.verifying}\nNeeds attention: ${u.attention}\nLast upload activity: ${u.activityAt || 'not reported'}\nOldest saved item: ${u.oldestAt || 'not reported'}\nPending media is retained on iPad. Only public verification establishes availability.`:'Upload metrics not reported by this app version or observation unavailable; prior incidents remain last known.');
    }
    const event=`Last reported event: ${state.eventReference || 'none reported'}\nEvent state: ${state.eventState || 'unknown / not reported'}\nGuest: ${state.guest || 'unknown / not reported'}\nLast observed guest activity: ${state.activityAt || 'not reported'}\nGuest inactivity alone is not a fault; automated stall detection is not supported.`;
    if(command==='event') return intro+event;
    const health=await env.DB.prepare('SELECT checked_at,available,reconciliation_fresh FROM backend_health WHERE id=?').bind('payments').first();
    const backend=health?`${health.available?'available':'unavailable'} at ${new Date(health.checked_at).toISOString()}${time-health.checked_at>=900000?' (STALE)':''}`:'not independently checked';
    const count=incidents.filter(i=>!['printer','uncertain_print'].includes(i.code)).length+(printerEpisode?.active || incidents.some(i=>['printer','uncertain_print'].includes(i.code))?1:0);
    return intro+`Last reported booth: ${state.mode}\nNetwork path: ${state.network} (does not prove internet reachability)\n${printerText(state)}\nOutstanding physical-print review: ${incidents.some(i=>i.code==='uncertain_print') || (printerEpisode?.active && (printerEpisode.components&2))?'unresolved (last known; /incidents)':'none recorded; physical output NOT VERIFIED'}\nCamera: ${state.camera || 'unknown / not checked'} (passive observation)\nDevice payment state: ${state.payment}\nPayment backend: ${backend}\nStorage: ${state.storage}\nUnresolved last-known issues: ${count} (includes informational observations; /incidents)\n`+event;
}

async function deliverCommands(env,time=Date.now(),limit=3) {
    if(!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_CHAT_ID) return;
    const due=(await env.DB.prepare('SELECT * FROM telegram_commands WHERE delivered_at IS NULL AND attempts<5 AND next_at<=? AND (lease_until IS NULL OR lease_until<=?) ORDER BY created_at LIMIT 3').bind(time,time).all()).results || [];
    for(const item of due.slice(0,limit)) {
        const lease=Date.now()+30000;
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
