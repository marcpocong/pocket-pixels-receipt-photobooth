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
