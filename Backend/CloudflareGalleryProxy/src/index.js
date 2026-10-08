const TOKEN_PATTERN = /^[a-f0-9]{64}$/;
const ALLOWED_UPSTREAM_HOSTS = new Set([
  "script.google.com",
  "script.googleusercontent.com",
]);
const COMPLETED_GALLERY_MARKER = 'data-pocket-pixels-gallery-status="complete"';
const COMPLETED_GALLERY_TTL_SECONDS = 3600;
// Upstream pages are recognised by the structural completed-gallery marker, the Made to Keep
// Studios brand, or the legacy Pocket Pixels brand still served until Apps Script is redeployed.
// Google sign-in and error pages contain none of these and are never proxied as a gallery.
const RECOGNISED_GALLERY_TEXT = [
  COMPLETED_GALLERY_MARKER,
  "Made to Keep Studios",
  "Pocket Pixels",
];

export function isRecognisedGalleryHTML(html) {
  return RECOGNISED_GALLERY_TEXT.some((marker) => html.includes(marker));
}

export default {
  async fetch(request, env) {
    const requestURL = new URL(request.url);

    // Safe proxy health check. Does not require or expose a gallery token.
    if (request.method === "GET" && requestURL.searchParams.get("diagnostic") === "proxy") {
      return proxyDiagnostic(env);
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return errorResponse(
        "Gallery unavailable.",
        "This request cannot be opened.",
        405,
        request.method,
        "METHOD_NOT_ALLOWED"
      );
    }

    const token = requestURL.searchParams.get("g") || "";
    if (!TOKEN_PATTERN.test(token)) {
      return errorResponse(
        "Gallery unavailable.",
        "This gallery link cannot be opened.",
        404,
        request.method,
        "INVALID_GALLERY_TOKEN"
      );
    }

    const cache = globalThis.caches && globalThis.caches.default;
    const cacheKey = canonicalCacheRequest(requestURL, token);
    if (cache) {
      const cached = await cache.match(cacheKey);
      if (cached) {
        return responseForMethod(cached, request.method, "HIT");
      }
    }

    const originCheck = validateOrigin(env.APPS_SCRIPT_GALLERY_ORIGIN);
    if (!originCheck.ok) {
      return temporaryError(request.method, originCheck.code);
    }

    const upstreamURL = new URL(originCheck.url);
    upstreamURL.search = "";
    upstreamURL.hash = "";

    // IMPORTANT: request Apps Script's raw proxy representation.
    // A normal HtmlService web-app response is an iframe sandbox wrapper;
    // proxying that wrapper through workers.dev leaves a blank iframe.
    upstreamURL.searchParams.set("proxy", "raw");
    upstreamURL.searchParams.set("g", token);

    let fetched;
    try {
      fetched = await fetchGoogleWithSafeRedirects(upstreamURL.toString());
    } catch (error) {
      console.log("Pocket Pixels proxy: upstream fetch failed.");
      return temporaryError(request.method, "UPSTREAM_FETCH_FAILED");
    }

    if (!fetched.ok) {
      console.log(
        "Pocket Pixels proxy: upstream failed code=" +
          fetched.code +
          " status=" +
          fetched.status
      );
      return temporaryError(request.method, fetched.code);
    }

    let html;
    try {
      html = await fetched.response.text();
    } catch (error) {
      return temporaryError(request.method, "UPSTREAM_BODY_READ_FAILED");
    }

    // Do not proxy a Google login/error page as if it were the gallery.
    if (!isRecognisedGalleryHTML(html)) {
      console.log(
        "Pocket Pixels proxy: unexpected upstream HTML host=" +
          fetched.finalHost +
          " status=" +
          fetched.status
      );
      return temporaryError(request.method, "UNEXPECTED_UPSTREAM_PAGE");
    }

    const isCompletedGallery = html.includes(COMPLETED_GALLERY_MARKER);
    const headers = securityHeaders(isCompletedGallery);
    headers.set("Content-Type", "text/html; charset=utf-8");
    headers.set("X-Pocket-Pixels-Proxy", "ok");
    headers.set("X-Pocket-Pixels-Cache", isCompletedGallery ? "MISS" : "BYPASS");

    const response = new Response(html, {
      status: 200,
      headers,
    });

    if (isCompletedGallery && cache) {
      await cache.put(cacheKey, response.clone());
    }

    return responseForMethod(response, request.method, headers.get("X-Pocket-Pixels-Cache"));
  },
};

function canonicalCacheRequest(requestURL, token) {
  const canonical = new URL(requestURL.origin + requestURL.pathname);
  canonical.searchParams.set("g", token);
  return new Request(canonical.toString(), { method: "GET" });
}

function responseForMethod(response, method, cacheStatus) {
  const headers = new Headers(response.headers);
  headers.set("X-Pocket-Pixels-Cache", cacheStatus);
  return new Response(method === "HEAD" ? null : response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function validateOrigin(rawValue) {
  const raw = String(rawValue || "").trim();
  if (!raw) {
    return { ok: false, code: "CONFIG_MISSING" };
  }

  let url;
  try {
    url = new URL(raw);
  } catch (error) {
    return { ok: false, code: "CONFIG_INVALID_URL" };
  }

  const valid =
    url.protocol === "https:" &&
    url.hostname === "script.google.com" &&
    /^\/macros\/s\/[^/]+\/exec\/?$/.test(url.pathname) &&
    !url.search &&
    !url.hash;

  if (!valid) {
    return { ok: false, code: "CONFIG_INVALID_ORIGIN" };
  }

  // Normalize a harmless trailing slash.
  url.pathname = url.pathname.replace(/\/+$/, "");
  return { ok: true, url: url.toString() };
}

async function fetchGoogleWithSafeRedirects(initialURL) {
  let currentURL = initialURL;

  for (let hop = 0; hop < 6; hop++) {
    const parsed = new URL(currentURL);
    if (
      parsed.protocol !== "https:" ||
      !ALLOWED_UPSTREAM_HOSTS.has(parsed.hostname)
    ) {
      return {
        ok: false,
        code: "UNSAFE_REDIRECT_HOST",
        status: 0,
        finalHost: parsed.hostname || "",
      };
    }

    let response;
    try {
      response = await fetch(currentURL, {
        method: "GET",
        redirect: "manual",
        headers: {
          Accept: "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
          "User-Agent":
            "Mozilla/5.0 (compatible; PocketPixelsGalleryProxy/1.0)",
        },
      });
    } catch (error) {
      return {
        ok: false,
        code: "UPSTREAM_FETCH_FAILED",
        status: 0,
        finalHost: parsed.hostname,
      };
    }

    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) {
        return {
          ok: false,
          code: "REDIRECT_WITHOUT_LOCATION",
          status: response.status,
          finalHost: parsed.hostname,
        };
      }

      let next;
      try {
        next = new URL(location, currentURL);
      } catch (error) {
        return {
          ok: false,
          code: "INVALID_REDIRECT_LOCATION",
          status: response.status,
          finalHost: parsed.hostname,
        };
      }

      if (
        next.protocol !== "https:" ||
        !ALLOWED_UPSTREAM_HOSTS.has(next.hostname)
      ) {
        return {
          ok: false,
          code: "UNSAFE_REDIRECT_HOST",
          status: response.status,
          finalHost: next.hostname || "",
        };
      }

      currentURL = next.toString();
      continue;
    }

    return {
      ok: response.ok,
      code: response.ok ? "OK" : "UPSTREAM_STATUS_" + response.status,
      status: response.status,
      finalHost: parsed.hostname,
      contentType: response.headers.get("content-type") || "",
      response,
    };
  }

  return {
    ok: false,
    code: "TOO_MANY_REDIRECTS",
    status: 0,
    finalHost: "",
  };
}

async function proxyDiagnostic(env) {
  const originCheck = validateOrigin(env.APPS_SCRIPT_GALLERY_ORIGIN);

  if (!originCheck.ok) {
    return jsonResponse({
      ok: false,
      proxyVersion: "phase6c-worker-raw-html-20260831",
      configPresent: !!String(env.APPS_SCRIPT_GALLERY_ORIGIN || "").trim(),
      configValid: false,
      stage: originCheck.code,
    });
  }

  const diagnosticURL = new URL(originCheck.url);
  diagnosticURL.searchParams.set("diagnostic", "phase6b");

  const result = await fetchGoogleWithSafeRedirects(diagnosticURL.toString());

  let bodyLooksLikeBackendDiagnostic = false;
  let backendVersion = "";

  if (result.ok) {
    try {
      const text = await result.response.text();
      const parsed = JSON.parse(text);
      bodyLooksLikeBackendDiagnostic =
        parsed &&
        parsed.ok === true &&
        parsed.status === "diagnostic";
      backendVersion =
        typeof parsed.backendVersion === "string"
          ? parsed.backendVersion
          : "";
    } catch (error) {
      bodyLooksLikeBackendDiagnostic = false;
    }
  }

  return jsonResponse({
    ok: result.ok && bodyLooksLikeBackendDiagnostic,
    proxyVersion: "phase6c-worker-raw-html-20260831",
    configPresent: true,
    configValid: true,
    upstreamStatus: result.status || 0,
    upstreamResult: result.code || "",
    finalHost: result.finalHost || "",
    contentType: result.contentType || "",
    backendDiagnosticRecognized: bodyLooksLikeBackendDiagnostic,
    backendVersion: backendVersion,
    rawProxyExpected: true,
  });
}

function securityHeaders(isCompletedGallery = false) {
  const headers = new Headers();
  if (isCompletedGallery) {
    headers.set("Cache-Control", `public, max-age=${COMPLETED_GALLERY_TTL_SECONDS}`);
  } else {
    headers.set("Cache-Control", "no-store, max-age=0");
    headers.set("Pragma", "no-cache");
  }
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("X-Robots-Tag", "noindex, nofollow");
  return headers;
}

function errorResponse(title, message, status, method, reference) {
  const headers = securityHeaders();
  headers.set("Content-Type", "text/html; charset=utf-8");
  headers.set("X-Pocket-Pixels-Proxy-Error", reference);

  return new Response(
    method === "HEAD" ? null : errorPage(title, message, reference),
    { status, headers }
  );
}

function temporaryError(method, reference) {
  return errorResponse(
    "We couldn't load your gallery right now.",
    "Please try again in a moment.",
    503,
    method,
    reference || "TEMPORARY_ERROR"
  );
}

function jsonResponse(value) {
  const headers = securityHeaders();
  headers.set("Content-Type", "application/json; charset=utf-8");
  return new Response(JSON.stringify(value, null, 2), {
    status: 200,
    headers,
  });
}

function errorPage(title, message, reference) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="robots" content="noindex,nofollow">
  <title>Made to Keep Studios Gallery</title>
  <style>
    *{box-sizing:border-box}
    body{margin:0;min-height:100vh;display:grid;place-items:center;padding:calc(28px + env(safe-area-inset-top)) 20px calc(42px + env(safe-area-inset-bottom));background:radial-gradient(120% 80% at 50% 0%,#fbf7f1 0%,rgba(251,247,241,0) 60%),linear-gradient(180deg,#f7f1e9 0%,#f3ece2 100%);color:#2b2422;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif}
    main{width:min(100%,480px);text-align:center;padding:36px 24px;background:rgba(251,247,241,.82);border:1px solid rgba(112,6,11,.22);border-radius:2px;box-shadow:0 14px 32px rgba(110,90,72,.1)}
    .brand{display:grid;justify-items:center;gap:6px;margin:0 0 18px;color:#70060b}
    .brand-descriptor{font-size:11px;font-weight:500;text-transform:uppercase;letter-spacing:.24em}
    .brand-rule{width:34px;height:1.5px;background:#70060b;margin:2px 0 4px}
    .brand-wordmark{font-family:"Bodoni 72","Bodoni Moda",Didot,Georgia,serif;font-style:italic;font-size:48px;line-height:.92;letter-spacing:-.04em}
    .brand-secondary{font-weight:300;font-size:17px;letter-spacing:.42em;margin-right:-.42em}
    h1{margin:8px 0 12px;color:#70060b;font-family:"Bodoni 72","Bodoni Moda",Didot,Georgia,serif;font-style:italic;font-size:clamp(30px,8vw,42px);font-weight:400;line-height:1.02}
    p{margin:0;color:#6b5f57;line-height:1.5}
    button{margin-top:24px;min-height:46px;padding:11px 22px;border:1.5px solid #70060b;border-radius:999px;background:transparent;color:#70060b;font-family:"Bodoni 72",Didot,Georgia,serif;font-size:15px;letter-spacing:.2em;text-transform:uppercase;cursor:pointer}
    button:focus-visible{outline:2px solid #70060b;outline-offset:3px}
  </style>
</head>
<body>
  <main>
    <div class="brand" role="img" aria-label="Made to Keep Studios"><span class="brand-descriptor">Receipt Photobooth</span><span class="brand-rule"></span><span class="brand-wordmark">made to keep</span><span class="brand-secondary">studios</span></div>
    <h1>${escapeHTML(title)}</h1>
    <p>${escapeHTML(message)}</p>
    <button onclick="window.location.reload()">Try Again</button>
  </main>
</body>
</html>`;
}

function escapeHTML(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
