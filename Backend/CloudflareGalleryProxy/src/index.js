const TOKEN_PATTERN = /^[a-f0-9]{64}$/;

const SECURITY_HEADERS = {
  "Cache-Control": "no-store, private",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "X-Robots-Tag": "noindex, nofollow"
};

export default {
  async fetch(request, env) {
    return handleRequest(request, env);
  }
};

export async function handleRequest(request, env) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return textResponse("Method not allowed.", 405, "text/plain; charset=utf-8", request.method);
  }

  const requestURL = new URL(request.url);
  const token = requestURL.searchParams.get("g") || "";
  if (!TOKEN_PATTERN.test(token)) {
    return htmlResponse(unavailablePage("Gallery unavailable.", ""), 200, request.method);
  }

  let upstreamURL;
  try {
    upstreamURL = makeUpstreamURL(env.APPS_SCRIPT_GALLERY_ORIGIN, token);
  } catch (error) {
    console.error(`Pocket Pixels proxy configuration error for token ${redactToken(token)}.`);
    return htmlResponse(temporaryErrorPage(), 502, request.method);
  }

  try {
    const upstreamResponse = await fetch(upstreamURL, {
      method: "GET",
      redirect: "follow",
      headers: {
        "Accept": "text/html"
      }
    });

    if (!upstreamResponse.ok) {
      console.error(`Pocket Pixels upstream returned ${upstreamResponse.status} for token ${redactToken(token)}.`);
      return htmlResponse(temporaryErrorPage(), 502, request.method);
    }

    const html = await upstreamResponse.text();
    return htmlResponse(html, 200, request.method);
  } catch (error) {
    console.error(`Pocket Pixels upstream unavailable for token ${redactToken(token)}.`);
    return htmlResponse(temporaryErrorPage(), 502, request.method);
  }
}

export function makeUpstreamURL(origin, token) {
  if (!TOKEN_PATTERN.test(token)) {
    throw new Error("Invalid gallery token.");
  }

  const parsed = new URL(String(origin || "").trim());
  if (
    parsed.protocol !== "https:" ||
    parsed.hostname !== "script.google.com" ||
    !/^\/macros\/s\/[^/]+\/exec$/.test(parsed.pathname) ||
    parsed.pathname.includes("/macros/u/") ||
    parsed.search !== "" ||
    parsed.hash !== ""
  ) {
    throw new Error("APPS_SCRIPT_GALLERY_ORIGIN must be the canonical Apps Script /macros/s/.../exec URL.");
  }

  parsed.searchParams.set("g", token);
  return parsed.toString();
}

export function redactToken(token) {
  const value = String(token || "");
  if (value.length <= 12) {
    return "<redacted>";
  }

  return `${value.slice(0, 6)}...${value.slice(-6)}`;
}

function htmlResponse(html, status, method) {
  return textResponse(html, status, "text/html; charset=utf-8", method);
}

function textResponse(body, status, contentType, method) {
  const headers = new Headers({
    ...SECURITY_HEADERS,
    "Content-Type": contentType
  });
  return new Response(method === "HEAD" ? null : body, { status, headers });
}

function unavailablePage(title, message) {
  return pageShell(title, message, "");
}

function temporaryErrorPage() {
  return pageShell(
    "We couldn't load your gallery right now. Please try again.",
    "",
    '<button type="button" onclick="window.location.reload()">Retry</button>'
  );
}

function pageShell(title, message, actionHTML) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><meta name="robots" content="noindex,nofollow"><title>Pocket Pixels Gallery</title><style>:root{color-scheme:light;--ink:#27191b;--muted:#6d5b5e;--paper:#fffdf9;--line:#eadcda;--accent:#8b1e2d;--focus:#0f62fe;}*{box-sizing:border-box;}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;background:var(--paper);color:var(--ink);}.center-page{min-height:100vh;display:grid;place-items:center;padding:32px 20px;}.notice{width:min(100%,460px);text-align:center;background:white;border:1px solid var(--line);border-radius:8px;padding:28px 20px;box-shadow:0 1px 12px rgba(39,25,27,.06);}.brand{text-transform:uppercase;letter-spacing:.08em;color:var(--accent);font-weight:900;margin:0 0 4px;}h1{font-size:32px;line-height:1.08;margin:4px 0 10px;letter-spacing:0;}p{color:var(--muted);margin:0;}button{min-height:44px;border-radius:8px;border:1px solid var(--accent);padding:11px 16px;background:var(--accent);color:white;font:inherit;font-weight:700;cursor:pointer;margin-top:18px;}button:focus-visible{outline:3px solid var(--focus);outline-offset:3px;}</style></head><body><main class="center-page"><section class="notice"><p class="brand">Pocket Pixels</p><h1>${escapeHTML(title)}</h1>${message ? `<p>${escapeHTML(message)}</p>` : ""}${actionHTML}</section></main></body></html>`;
}

function escapeHTML(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
