// Best-effort single-flight within one Worker isolate. No persistent capabilities or logs.
// Different isolates/regions still have independent origin work; edge Cache API is regional.
const inFlight = new Map();
const MAX_IN_FLIGHT_GALLERIES = 32;

export async function coalescedGalleryResponse(key, produce, context, metrics) {
  let pending = inFlight.get(key);
  if (pending) {
    metrics.coalesced = 1;
  } else {
    const writes = [];
    const producerContext = {waitUntil(promise) {
      writes.push(promise);
      if (context?.waitUntil) context.waitUntil(promise);
    }};
    pending = Promise.resolve().then(async () => {
      const response = await produce(context?.waitUntil ? producerContext : undefined);
      // Independent response bodies avoid sharing/consuming another visitor's stream.
      return {body:await response.text(), status:response.status, headers:new Headers(response.headers)};
    });
    if (inFlight.size < MAX_IN_FLIGHT_GALLERIES) {
      inFlight.set(key, pending);
      const release = () => { if (inFlight.get(key) === pending) inFlight.delete(key); };
      // Retain only until the optional cache write finishes, covering the response→cache race.
      const lifetime = pending.then(() => Promise.allSettled(writes)).then(release, release);
      // The registered cache-write promise keeps its cleanup microtask alive.
      void lifetime;
    }
  }
  const waitStarted = performance.now();
  const result = await pending;
  if (metrics.coalesced) metrics.coalescedWaitMs = performance.now() - waitStarted;
  const headers = new Headers(result.headers);
  if (metrics.coalesced && headers.get("X-Pocket-Pixels-Cache") === "MISS") headers.set('X-Pocket-Pixels-Cache', 'COALESCED');
  return new Response(result.body, {status:result.status, headers});
}
