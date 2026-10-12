import assert from "node:assert/strict";
import test from "node:test";
import worker from "../src/index.js";

const token = "a".repeat(64);
const env = {
  APPS_SCRIPT_GALLERY_ORIGIN: "https://script.google.com/macros/s/DEPLOYMENT_ID/exec",
};

test("valid 64-char token forwards raw proxy request correctly", async () => {
  const calls = await withMockFetch([
    new Response("<!doctype html><title>Pocket Pixels Gallery</title>", {
      status: 200,
      headers: { "Content-Type": "text/plain", "Set-Cookie": "SID=secret" },
    }),
  ], async (calls) => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.equal(response.status, 200);
    assert.match(await response.text(), /Pocket Pixels Gallery/);
    assert.equal(calls[0].url, `https://script.google.com/macros/s/DEPLOYMENT_ID/exec?proxy=raw&g=${token}`);
    assert.equal(calls[0].init.method, "GET");
    assert.equal(calls[0].init.redirect, "manual");
  });

  assert.equal(calls.length, 1);
});

test("uppercase token rejected", async () => {
  await assertInvalidToken("A".repeat(64));
});

test("short token rejected", async () => {
  await assertInvalidToken("a".repeat(63));
});

test("malformed token rejected", async () => {
  await assertInvalidToken(`${"a".repeat(63)}z`);
});

test("no g rejected", async () => {
  await withMockFetch([new Response("should not be called")], async (calls) => {
    const response = await worker.fetch(new Request("https://gallery.example.com/"), env);
    assert.equal(response.status, 404);
    assert.match(await response.text(), /Gallery unavailable\./);
    assert.equal(calls.length, 0);
  });
});

test("POST rejected", async () => {
  await withMockFetch([new Response("should not be called")], async (calls) => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`, { method: "POST" }), env);
    assert.equal(response.status, 405);
    assert.equal(calls.length, 0);
  });
});

test("arbitrary upstream injection impossible", async () => {
  await withMockFetch([new Response("should not be called")], async (calls) => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), {
      APPS_SCRIPT_GALLERY_ORIGIN: "https://evil.example.com/exec",
    });
    assert.equal(response.status, 503);
    assert.equal(calls.length, 0);
  });

  await withMockFetch([new Response("should not be called")], async (calls) => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), {
      APPS_SCRIPT_GALLERY_ORIGIN: "https://script.google.com/macros/u/2/s/DEPLOYMENT_ID/exec",
    });
    assert.equal(response.status, 503);
    assert.equal(calls.length, 0);
  });
});

test("browser Cookie and Google auth headers are not sent upstream", async () => {
  await withMockFetch([
    new Response("<!doctype html><title>Pocket Pixels Gallery</title>"),
  ], async (calls) => {
    await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`, {
      headers: {
        Cookie: "SID=secret",
        Authorization: "Bearer secret",
        "X-Goog-AuthUser": "2",
      },
    }), env);
    const headers = new Headers(calls[0].init.headers);
    assert.equal(headers.get("Cookie"), null);
    assert.equal(headers.get("Authorization"), null);
    assert.equal(headers.get("X-Goog-AuthUser"), null);
  });
});

test("expected Google upstream redirects are followed manually", async () => {
  await withMockFetch([
    new Response(null, {
      status: 302,
      headers: { Location: "https://script.googleusercontent.com/macros/echo?user_content_key=ok" },
    }),
    new Response("<!doctype html><title>Pocket Pixels Gallery</title>", {
      status: 200,
      headers: { "Content-Type": "text/plain" },
    }),
  ], async (calls) => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.equal(response.status, 200);
    assert.equal(calls.length, 2);
    assert.equal(new URL(calls[1].url).hostname, "script.googleusercontent.com");
  });
});

test("upstream HTML returned as text/html", async () => {
  await withMockFetch([
    new Response("<!doctype html><title>Pocket Pixels Gallery</title>"),
  ], async () => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.match(await response.text(), /Pocket Pixels Gallery/);
    assert.equal(response.headers.get("Content-Type"), "text/html; charset=utf-8");
  });
});

test("no Set-Cookie returned to customer", async () => {
  await withMockFetch([
    new Response("<!doctype html><title>Pocket Pixels Gallery</title>", {
      headers: { "Set-Cookie": "SID=secret" },
    }),
  ], async () => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.equal(response.headers.get("Set-Cookie"), null);
  });
});

test("Cache-Control no-store", async () => {
  await withMockFetch([
    new Response("<!doctype html><title>Pocket Pixels Gallery</title>"),
  ], async () => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.equal(response.headers.get("Cache-Control"), "no-store, max-age=0");
  });
});

test("completed gallery is fetched once and then served from edge cache", async () => {
  await withMemoryCache(async () => {
    await withMockFetch([
      completedGalleryResponse(),
    ], async (calls) => {
      const request = new Request(`https://gallery.example.com/?g=${token}`);
      const first = await worker.fetch(request, env);
      assert.equal(first.headers.get("X-Pocket-Pixels-Cache"), "MISS");
      assert.equal(first.headers.get("Cache-Control"), "public, max-age=3600");

      const second = await worker.fetch(request, env);
      assert.equal(second.headers.get("X-Pocket-Pixels-Cache"), "HIT");
      assert.match(await second.text(), /your photos are ready/);
      assert.equal(calls.length, 1);
    });
  });
});

test("completed cache uses an internal release version without changing the upstream or customer URL", async () => {
  await withMemoryCache(async (entries) => {
    await withMockFetch([completedGalleryResponse()], async (calls) => {
      const customerURL = `https://gallery.example.com/?g=${token}`;
      const response = await worker.fetch(new Request(customerURL), env);
      assert.equal(response.status, 200);
      assert.equal(calls[0].url, `https://script.google.com/macros/s/DEPLOYMENT_ID/exec?proxy=raw&g=${token}`);
      assert.ok([...entries.keys()].some((key) => key.includes("gallery-cache=made-to-keep-20261009")));
      assert.ok(!customerURL.includes("gallery-cache"));
    });
  });
});

test("completed schema-v2 GIF gallery HTML passes through and remains in cache", async () => {
  await withMemoryCache(async () => {
    const gifHTML = '<!doctype html><title>Pocket Pixels Gallery</title><main data-pocket-pixels-gallery-status="complete"><h2>Your GIF</h2><img id="image-session.gif" data-open="session.gif"><button data-download="session.gif">Save GIF</button></main>';
    await withMockFetch([new Response(gifHTML)], async () => {
      const request = new Request(`https://gallery.example.com/?g=${token}`);
      const first = await worker.fetch(request, env);
      assert.equal(await first.text(), gifHTML);
      const cached = await worker.fetch(request, env);
      const cachedHTML = await cached.text();
      assert.match(cachedHTML, /image-session\.gif/);
      assert.match(cachedHTML, /Save GIF/);
    });
  });
});

test("pending and error responses are never cached", async () => {
  await withMemoryCache(async () => {
    await withMockFetch([
      new Response("<!doctype html><title>Pocket Pixels Gallery</title><p>still being prepared</p>"),
      new Response("<!doctype html><title>Pocket Pixels Gallery</title><p>still being prepared</p>"),
    ], async (calls) => {
      const request = new Request(`https://gallery.example.com/?g=${token}`);
      const first = await worker.fetch(request, env);
      const second = await worker.fetch(request, env);
      assert.equal(first.headers.get("X-Pocket-Pixels-Cache"), "BYPASS");
      assert.equal(second.headers.get("X-Pocket-Pixels-Cache"), "BYPASS");
      assert.equal(first.headers.get("Cache-Control"), "no-store, max-age=0");
      assert.equal(calls.length, 2);
    });
  });

  await withMemoryCache(async () => {
    await withMockFetch([
      new Response("upstream error", { status: 500 }),
      new Response("upstream error", { status: 500 }),
    ], async (calls) => {
      const request = new Request(`https://gallery.example.com/?g=${token}`);
      assert.equal((await worker.fetch(request, env)).status, 503);
      assert.equal((await worker.fetch(request, env)).status, 503);
      assert.equal(calls.length, 2);
    });
  });
});

test("HEAD uses completed GET cache without returning a body", async () => {
  await withMemoryCache(async () => {
    await withMockFetch([completedGalleryResponse()], async (calls) => {
      await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), env);
      const head = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`, { method: "HEAD" }), env);
      assert.equal(head.status, 200);
      assert.equal(head.headers.get("X-Pocket-Pixels-Cache"), "HIT");
      assert.equal(await head.text(), "");
      assert.equal(calls.length, 1);
    });
  });
});

test("completed cache strips sensitive upstream headers and keeps security headers", async () => {
  await withMemoryCache(async () => {
    await withMockFetch([completedGalleryResponse({
      "Set-Cookie": "SID=secret",
      Authorization: "secret",
    })], async () => {
      const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), env);
      assert.equal(response.headers.get("Set-Cookie"), null);
      assert.equal(response.headers.get("Authorization"), null);
      assert.equal(response.headers.get("X-Robots-Tag"), "noindex, nofollow");
      assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
    });
  });
});

test("customer token is not logged in full", async () => {
  const logs = [];
  const originalLog = console.log;
  console.log = (message) => logs.push(String(message));
  try {
    await withMockFetch([
      new Response("bad", { status: 500 }),
    ], async () => {
      await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), env);
    });
  } finally {
    console.log = originalLog;
  }

  assert.ok(logs.length > 0);
  assert.ok(!logs.some((line) => line.includes(token)));
});

test("diagnostic route expects raw proxy backend", async () => {
  await withMockFetch([
    new Response(JSON.stringify({
      ok: true,
      status: "diagnostic",
      backendVersion: "phase6c-worker-raw-html-proxy-20260831",
      rawProxyRoute: true,
    }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }),
  ], async () => {
    const response = await worker.fetch(new Request("https://gallery.example.com/?diagnostic=proxy"), env);
    const body = await response.json();
    assert.equal(body.ok, true);
    assert.equal(body.proxyVersion, "phase6c-worker-raw-html-20260831");
    assert.equal(body.backendVersion, "phase6c-worker-raw-html-proxy-20260831");
    assert.equal(body.rawProxyExpected, true);
  });
});

async function assertInvalidToken(value) {
  await withMockFetch([new Response("should not be called")], async (calls) => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${encodeURIComponent(value)}`), env);
    assert.equal(response.status, 404);
    assert.match(await response.text(), /Gallery unavailable\./);
    assert.equal(calls.length, 0);
  });
}

async function withMockFetch(responses, operation) {
  const originalFetch = globalThis.fetch;
  const calls = [];
  const queue = [...responses];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const response = queue.shift() || responses[responses.length - 1];
    return response.clone();
  };

  try {
    await operation(calls);
    return calls;
  } finally {
    globalThis.fetch = originalFetch;
  }
}

function completedGalleryResponse(headers = {}) {
  return new Response(
    '<!doctype html><title>Pocket Pixels Gallery</title><main data-pocket-pixels-gallery-status="complete">your photos are ready</main>',
    { status: 200, headers }
  );
}

async function withMemoryCache(operation) {
  const originalCaches = globalThis.caches;
  const entries = new Map();
  globalThis.caches = {
    default: {
      async match(request) {
        const response = entries.get(request.url);
        return response ? response.clone() : undefined;
      },
      async put(request, response) {
        entries.set(request.url, response.clone());
      },
    },
  };

  try {
    await operation(entries);
  } finally {
    if (originalCaches === undefined) {
      delete globalThis.caches;
    } else {
      globalThis.caches = originalCaches;
    }
  }
}

// Made to Keep Studios visible rebrand (Phase 1): the Worker must accept the new gallery HTML,
// keep accepting legacy Pocket Pixels HTML until Apps Script is redeployed, and still refuse
// Google sign-in/error pages.
const madeToKeepCompletedHTML =
  '<!doctype html><title>Made to Keep Studios Gallery</title><main class="gallery-shell" data-pocket-pixels-gallery-status="complete"><div class="brand-lockup" role="img" aria-label="Made to Keep Studios"></div><h2>Your GIF</h2><img id="image-session.gif"><p>Color Receipt</p><p>Thermal Receipt</p></main>';

test("Made to Keep Studios completed gallery is accepted and cached", async () => {
  await withMemoryCache(async () => {
    await withMockFetch([new Response(madeToKeepCompletedHTML)], async (calls) => {
      const request = new Request(`https://gallery.example.com/?g=${token}`);
      const first = await worker.fetch(request, env);
      assert.equal(first.status, 200);
      assert.equal(first.headers.get("X-Pocket-Pixels-Cache"), "MISS");
      assert.equal(await first.text(), madeToKeepCompletedHTML);
      const second = await worker.fetch(request, env);
      assert.equal(second.headers.get("X-Pocket-Pixels-Cache"), "HIT");
      assert.match(await second.text(), /Made to Keep Studios Gallery/);
      assert.equal(calls.length, 1);
    });
  });
});

test("Made to Keep Studios pending page is accepted but never cached", async () => {
  await withMemoryCache(async () => {
    const pending = '<!doctype html><title>Made to Keep Studios Gallery</title><main class="center-page"><h1>your photos are still being prepared.</h1></main>';
    await withMockFetch([new Response(pending), new Response(pending)], async (calls) => {
      const request = new Request(`https://gallery.example.com/?g=${token}`);
      const first = await worker.fetch(request, env);
      assert.equal(first.status, 200);
      assert.equal(first.headers.get("X-Pocket-Pixels-Cache"), "BYPASS");
      await worker.fetch(request, env);
      assert.equal(calls.length, 2);
    });
  });
});

test("legacy Pocket Pixels gallery HTML remains accepted for compatibility", async () => {
  await withMockFetch([completedGalleryResponse()], async () => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.equal(response.status, 200);
    assert.match(await response.text(), /data-pocket-pixels-gallery-status="complete"/);
  });
});

test("Google sign-in page is never proxied as a gallery", async () => {
  await withMockFetch([
    new Response("<!doctype html><title>Sign in - Google Accounts</title><form>Sign in</form>"),
  ], async () => {
    const response = await worker.fetch(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.equal(response.status, 503);
    assert.equal(response.headers.get("X-Pocket-Pixels-Proxy-Error"), "UNEXPECTED_UPSTREAM_PAGE");
    const html = await response.text();
    assert.match(html, /<title>Made to Keep Studios Gallery<\/title>/);
    assert.match(html, /aria-label="Made to Keep Studios"/);
    assert.doesNotMatch(html, /Pocket Pixels/);
  });
});

test("Worker error pages show Made to Keep Studios branding", async () => {
  const response = await worker.fetch(new Request("https://gallery.example.com/?g=bad"), env);
  const html = await response.text();
  assert.match(html, /made to keep/);
  assert.match(html, /studios/);
  assert.doesNotMatch(html, /Pocket Pixels|@pocketpixels\.ceb/i);
});

// Made to Keep gallery front-door migration (Phase 2): the same Worker source serves the legacy
// Pocket Pixels workers.dev host (already printed on receipts) and any future Made to Keep host.
// Token handling, upstream URL and cache semantics must not depend on the public hostname.
const legacyFrontDoor = "https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/";
const madeToKeepTestFrontDoor = "https://gallery.madetokeep.test/";

test("legacy and Made to Keep front doors forward the same token to the same upstream", async () => {
  await withMockFetch([
    new Response(madeToKeepCompletedHTML),
    new Response(madeToKeepCompletedHTML),
  ], async (calls) => {
    const legacy = await worker.fetch(new Request(`${legacyFrontDoor}?g=${token}`), env);
    const current = await worker.fetch(new Request(`${madeToKeepTestFrontDoor}?g=${token}`), env);
    assert.equal(legacy.status, 200);
    assert.equal(current.status, 200);
    assert.equal(await legacy.text(), await current.text());
    assert.equal(calls.length, 2);
    assert.equal(calls[0].url, `https://script.google.com/macros/s/DEPLOYMENT_ID/exec?proxy=raw&g=${token}`);
    assert.equal(calls[1].url, calls[0].url);
  });
});

test("legacy front door keeps serving old Pocket Pixels-era completed galleries from cache", async () => {
  await withMemoryCache(async () => {
    await withMockFetch([completedGalleryResponse()], async (calls) => {
      const request = new Request(`${legacyFrontDoor}?g=${token}`);
      const first = await worker.fetch(request, env);
      assert.equal(first.headers.get("X-Pocket-Pixels-Cache"), "MISS");
      assert.equal(first.headers.get("Cache-Control"), "public, max-age=3600");
      const second = await worker.fetch(request, env);
      assert.equal(second.headers.get("X-Pocket-Pixels-Cache"), "HIT");
      assert.equal(calls.length, 1);
    });
  });
});

test("Made to Keep front door serves schema-v2 GIF gallery with unchanged cache and HEAD semantics", async () => {
  await withMemoryCache(async () => {
    await withMockFetch([new Response(madeToKeepCompletedHTML)], async (calls) => {
      const first = await worker.fetch(new Request(`${madeToKeepTestFrontDoor}?g=${token}`), env);
      assert.equal(first.headers.get("X-Pocket-Pixels-Cache"), "MISS");
      assert.match(await first.text(), /image-session\.gif/);
      const head = await worker.fetch(new Request(`${madeToKeepTestFrontDoor}?g=${token}`, { method: "HEAD" }), env);
      assert.equal(head.status, 200);
      assert.equal(head.headers.get("X-Pocket-Pixels-Cache"), "HIT");
      assert.equal(await head.text(), "");
      assert.equal(calls.length, 1);
    });
  });
});

test("both front doors reject malformed tokens and Google sign-in pages identically", async () => {
  for (const frontDoor of [legacyFrontDoor, madeToKeepTestFrontDoor]) {
    const invalid = await worker.fetch(new Request(`${frontDoor}?g=${"A".repeat(64)}`), env);
    assert.equal(invalid.status, 404);
    await withMockFetch([
      new Response("<!doctype html><title>Sign in - Google Accounts</title><form>Sign in</form>"),
    ], async () => {
      const response = await worker.fetch(new Request(`${frontDoor}?g=${token}`), env);
      assert.equal(response.status, 503);
      assert.equal(response.headers.get("X-Pocket-Pixels-Proxy-Error"), "UNEXPECTED_UPSTREAM_PAGE");
      assert.match(response.headers.get("Cache-Control"), /no-store/);
    });
  }
});
