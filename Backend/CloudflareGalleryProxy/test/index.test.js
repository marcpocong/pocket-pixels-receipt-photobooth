import assert from "node:assert/strict";
import test from "node:test";
import { handleRequest, makeUpstreamURL, redactToken } from "../src/index.js";

const token = "a".repeat(64);
const env = {
  APPS_SCRIPT_GALLERY_ORIGIN: "https://script.google.com/macros/s/DEPLOYMENT_ID/exec"
};

test("valid 64-char token forwards correctly", async () => {
  const calls = await withMockFetch(new Response("<html>ok</html>", {
    status: 200,
    headers: { "Content-Type": "text/html", "Set-Cookie": "SID=secret" }
  }), async (calls) => {
    const response = await handleRequest(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "<html>ok</html>");
    assert.equal(calls[0].url, `https://script.google.com/macros/s/DEPLOYMENT_ID/exec?g=${token}`);
    assert.equal(calls[0].init.method, "GET");
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
  await withMockFetch(new Response("should not be called"), async (calls) => {
    const response = await handleRequest(new Request("https://gallery.example.com/"), env);
    assert.equal(response.status, 200);
    assert.match(await response.text(), /Gallery unavailable\./);
    assert.equal(calls.length, 0);
  });
});

test("POST rejected", async () => {
  await withMockFetch(new Response("should not be called"), async (calls) => {
    const response = await handleRequest(new Request(`https://gallery.example.com/?g=${token}`, { method: "POST" }), env);
    assert.equal(response.status, 405);
    assert.equal(calls.length, 0);
  });
});

test("arbitrary upstream injection impossible", () => {
  assert.equal(
    makeUpstreamURL(env.APPS_SCRIPT_GALLERY_ORIGIN, token),
    `https://script.google.com/macros/s/DEPLOYMENT_ID/exec?g=${token}`
  );
  assert.throws(() => makeUpstreamURL("https://evil.example.com/exec", token));
  assert.throws(() => makeUpstreamURL("https://script.google.com/macros/u/2/s/DEPLOYMENT_ID/exec", token));
});

test("browser Cookie header not sent upstream", async () => {
  await withMockFetch(new Response("<html>ok</html>"), async (calls) => {
    await handleRequest(new Request(`https://gallery.example.com/?g=${token}`, {
      headers: {
        Cookie: "SID=secret",
        Authorization: "Bearer secret",
        "X-Goog-AuthUser": "2"
      }
    }), env);
    assert.equal(new Headers(calls[0].init.headers).get("Cookie"), null);
    assert.equal(new Headers(calls[0].init.headers).get("Authorization"), null);
    assert.equal(new Headers(calls[0].init.headers).get("X-Goog-AuthUser"), null);
  });
});

test("upstream redirects followed", async () => {
  await withMockFetch(new Response("<html>ok</html>"), async (calls) => {
    await handleRequest(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.equal(calls[0].init.redirect, "follow");
  });
});

test("upstream HTML returned", async () => {
  await withMockFetch(new Response("<!doctype html><title>Pocket Pixels</title>"), async () => {
    const response = await handleRequest(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.match(await response.text(), /Pocket Pixels/);
    assert.equal(response.headers.get("Content-Type"), "text/html; charset=utf-8");
  });
});

test("no Set-Cookie returned to customer", async () => {
  await withMockFetch(new Response("<html>ok</html>", { headers: { "Set-Cookie": "SID=secret" } }), async () => {
    const response = await handleRequest(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.equal(response.headers.get("Set-Cookie"), null);
  });
});

test("Cache-Control no-store", async () => {
  await withMockFetch(new Response("<html>ok</html>"), async () => {
    const response = await handleRequest(new Request(`https://gallery.example.com/?g=${token}`), env);
    assert.equal(response.headers.get("Cache-Control"), "no-store, private");
  });
});

test("customer token not logged in full", async () => {
  const logs = [];
  const originalError = console.error;
  console.error = (message) => logs.push(String(message));
  try {
    await withMockFetch(new Response("bad", { status: 500 }), async () => {
      await handleRequest(new Request(`https://gallery.example.com/?g=${token}`), env);
    });
  } finally {
    console.error = originalError;
  }

  assert.equal(redactToken(token), "aaaaaa...aaaaaa");
  assert.ok(logs.length > 0);
  assert.ok(!logs.some((line) => line.includes(token)));
  assert.ok(logs.some((line) => line.includes("aaaaaa...aaaaaa")));
});

async function assertInvalidToken(value) {
  await withMockFetch(new Response("should not be called"), async (calls) => {
    const response = await handleRequest(new Request(`https://gallery.example.com/?g=${encodeURIComponent(value)}`), env);
    assert.equal(response.status, 200);
    assert.match(await response.text(), /Gallery unavailable\./);
    assert.equal(calls.length, 0);
  });
}

async function withMockFetch(response, operation) {
  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    return response.clone();
  };

  try {
    await operation(calls);
    return calls;
  } finally {
    globalThis.fetch = originalFetch;
  }
}
