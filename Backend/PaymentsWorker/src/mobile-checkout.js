export function mobileCheckoutPage() {
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Made to Keep Studios · Upload your receipt</title>
<style>
:root{color-scheme:light;--wine:#70060b;--paper:#f7f1e9;--light:#fbf7f1;--shade:#eee6dc;--ink:#2b2422;--muted:#6b5f57;--line:#d9ccbf;--serif:"Bodoni 72",Didot,Georgia,serif}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font:1rem/1.5 system-ui,sans-serif}
main{max-width:460px;margin:auto;padding:clamp(30px,8vw,48px) clamp(18px,6.4vw,32px) 36px}
header{text-align:center;color:var(--wine);margin-bottom:clamp(24px,7vw,36px)}
.wordmark{display:block;font:italic 2.5rem/.92 var(--serif);letter-spacing:-.065em}
.studios{display:block;margin-top:7px;font: .65rem/1.2 var(--serif);letter-spacing:.42em;text-indent:.42em}
header::after{display:block;content:"";width:36px;height:1px;margin:22px auto 0;background:var(--wine)}
h1{color:var(--wine);font:italic clamp(2rem,10vw,2.95rem)/1.04 var(--serif);letter-spacing:-.04em;text-align:center;margin:0}
h2{color:var(--wine);font:1.4rem/1.15 var(--serif);margin:0 0 12px}
p{margin:0;overflow-wrap:anywhere}
.summary{display:flex;flex-wrap:wrap;align-items:center;justify-content:center;gap:10px;margin:16px 0 27px;color:var(--muted)}
.amount{font:1.38rem/1.3 var(--serif);font-variant-numeric:lining-nums;color:var(--wine)}
.summary .divider{width:1px;height:16px;background:var(--line)}
section{margin:20px 0}
button,a.button,.picker{display:block;width:100%;min-height:48px;padding:11px 14px;border-radius:999px;border:1px solid var(--wine);background:var(--wine);color:var(--light);font:600 .96rem/1.45 system-ui,sans-serif;text-align:center;text-decoration:none;cursor:pointer}
button.secondary,a.secondary{background:transparent;color:var(--wine);margin-top:12px}
button:disabled{background:var(--shade);border-color:var(--line);color:var(--muted);cursor:default}
:focus-visible,.picker:has(input:focus-visible){outline:2px solid var(--wine);outline-offset:4px}
.picker{position:relative;display:flex;align-items:center;justify-content:center;gap:8px;background:var(--light);color:var(--wine);border-style:dashed;min-height:68px;border-radius:12px}
.picker:has(input:disabled){opacity:.65;cursor:default}
.picker input{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)}
.picker svg{width:19px;height:19px;flex:none}
#preview{display:block;width:100%;max-height:260px;object-fit:contain;margin-top:12px;padding:8px;border:1px solid var(--line);border-radius:10px;background:var(--light)}
.consent,.privacy{font-size:.84rem;color:var(--muted)}
.consent{margin:17px 0 11px;text-align:center}
.privacy{margin-top:22px;padding-top:14px;border-top:1px solid var(--line);text-align:center}
#notice{margin:18px 0;color:var(--wine);text-align:center}
#notice.success{padding:18px 14px;border-block:1px solid var(--line);font:1.35rem/1.3 var(--serif)}
progress{display:block;width:100%;height:12px;accent-color:var(--wine);margin-top:14px}
.legacy{padding:16px;border:1px solid var(--line);border-radius:12px;background:var(--light)}
#receiverQR{display:block;width:min(210px,100%);height:auto;margin:12px auto;background:white;padding:8px}
[hidden]{display:none!important}
</style>
</head>
<body>
<main>
<header aria-label="Made to Keep Studios"><span class="wordmark" aria-hidden="true">made to keep</span><span class="studios" aria-hidden="true">STUDIOS</span></header>
<h1 id="title">Upload your receipt</h1>
<div class="summary" id="checkout" hidden><span class="amount" id="amount"></span><span class="divider" aria-hidden="true"></span><span id="quantity"></span></div>
<section class="legacy" id="receiving-details" hidden>
<h2>Send payment</h2><p id="recipient"></p><p id="account"></p><p id="instructions"></p>
<button class="secondary" id="copy" type="button">Copy account details</button>
<img id="receiverQR" alt="Receiving-account payment QR" hidden>
<a class="button secondary" id="download" download="receiving-account-qr.jpg" hidden>Download payment QR</a>
</section>
<section id="evidence" hidden>
<label class="picker">
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="9" cy="9" r="1.5"/><path d="m4 18 5-5 3 3 4-5 5 6"/></svg>
<span id="file-label">Choose a payment screenshot</span>
<input id="file" type="file" accept="image/jpeg,image/png">
</label>
<img id="preview" alt="Selected payment screenshot" hidden>
<p class="consent">By submitting, you confirm that you’ve transferred the amount shown.</p>
<button id="upload" type="button" disabled>Submit receipt</button>
<progress id="progress" max="100" value="0" aria-label="Receipt upload progress" hidden></progress>
</section>
<button class="secondary" id="ack" type="button" hidden>I’ve paid</button>
<p id="notice" role="status" aria-live="polite">Opening your checkout…</p>
<button class="secondary" id="retry" type="button" hidden>Check receipt status</button>
<p class="privacy" id="privacy" hidden>Your screenshot is stored privately for the booth operator. It stays out of your photo gallery.</p>
</main>
<script>
(() => {
    'use strict';
    const byId = id => document.getElementById(id);
    const link = location.hash.slice(1).match(/^c=([a-f0-9-]{36}\\.[a-f0-9]{64})(&receipt=1)?$/);
    const capability = link?.[1];
    const receiptOnly = Boolean(link?.[2]);
    let checkout = null;
    let image = null;
    let busy = false;

    function notice(message, { retry = false, success = false } = {}) {
        byId('notice').textContent = message;
        byId('notice').classList.toggle('success', success);
        byId('retry').hidden = !retry;
    }

    function lock(value) {
        busy = value;
        byId('file').disabled = value;
        byId('upload').disabled = value || !image;
        byId('ack').disabled = value;
        byId('retry').disabled = value;
    }

    async function api(path, body = {}) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 30000);
        try {
            const response = await fetch('/v2/guest/' + path, {
                method: 'POST', cache: 'no-store', credentials: 'omit', signal: controller.signal,
                headers: { 'Content-Type': 'application/json', Authorization: 'Checkout ' + capability },
                body: JSON.stringify(body)
            });
            const data = await response.json();
            if (!response.ok) throw Error(data.message || 'Couldn’t open this checkout. Try again.');
            return data;
        } finally {
            clearTimeout(timer);
        }
    }

    function canContinueOnBooth(c) {
        return !c.closedAt && !c.completedAt && Date.parse(c.expiresAt) > Date.now();
    }

    function showReceiptReceived() {
        byId('evidence').hidden = true;
        byId('receiving-details').hidden = true;
        byId('ack').hidden = true;
        byId('privacy').hidden = false;
        notice('Receipt received. Return to the photobooth.', { success: true });
    }

    function render(c) {
        checkout = c;
        const legacyActive = !receiptOnly && canContinueOnBooth(c) && !c.acknowledgedAt && !c.receipt?.submitted;
        const acceptsImage = c.method === 'MANUAL_DIGITAL' && c.receiptPolicy !== 'ACK_ONLY';
        byId('title').textContent = acceptsImage ? 'Upload your receipt' : 'Your checkout';
        byId('amount').textContent = new Intl.NumberFormat('en-PH', { style: 'currency', currency: 'PHP' }).format(c.totalCentavos / 100);
        byId('quantity').textContent = c.copies + (c.copies === 1 ? ' copy' : ' copies');
        byId('checkout').hidden = false;
        byId('evidence').hidden = !acceptsImage || Boolean(c.receipt?.submitted);
        byId('privacy').hidden = !acceptsImage;
        byId('ack').hidden = !legacyActive || c.receiptPolicy === 'REQUIRED';
        byId('receiving-details').hidden = !legacyActive || !c.receiver;
        if (legacyActive && c.receiver) {
            const receiver = c.receiver;
            byId('recipient').textContent = [receiver.recipient, receiver.provider].filter(Boolean).join(' · ');
            byId('account').textContent = receiver.identifier || '';
            byId('instructions').textContent = receiver.instructions || '';
            if (receiver.qrJPEG) {
                const source = 'data:image/jpeg;base64,' + receiver.qrJPEG;
                byId('receiverQR').src = source;
                byId('download').href = source;
            }
            byId('receiverQR').hidden = !receiver.qrJPEG;
            byId('download').hidden = !receiver.qrJPEG;
        }
        if (c.receipt?.submitted) showReceiptReceived();
        else if (!canContinueOnBooth(c)) {
            notice(acceptsImage ? 'This session has ended. You can still send the receipt to the attendant.' : 'This session has ended. Ask the attendant for help.');
        } else if (!acceptsImage && c.acknowledgedAt) {
            notice('Payment acknowledgment saved. Return to the photobooth.', { success: true });
        } else {
            notice('');
        }
    }

    async function readStatus() {
        return api(receiptOnly ? 'status?receipt=1' : 'status');
    }

    async function refresh() {
        if (!capability) {
            notice('Scan the receipt QR on the photobooth to open your checkout.');
            return;
        }
        lock(true);
        try { render(await readStatus()); }
        catch (error) {
            const message = error instanceof TypeError || error.name === 'AbortError' ? 'Couldn’t connect. Check your connection and try again.' : error.message;
            notice(message, { retry: true });
        } finally { lock(false); }
    }

    byId('retry').onclick = refresh;
    byId('copy').onclick = async () => {
        try {
            await navigator.clipboard.writeText(checkout.receiver.identifier);
            notice('Account details copied.');
        } catch { notice('Copy the account details shown above.'); }
    };
    byId('ack').onclick = async () => {
        if (!checkout || busy || receiptOnly) return;
        lock(true);
        try { render(await api('acknowledgments', { snapshotHash: checkout.snapshotHash })); }
        catch (error) { notice(error.message, { retry: true }); }
        finally { lock(false); }
    };

    async function prepareImage(file) {
        if (!['image/jpeg', 'image/png'].includes(file.type) || file.size > 20 * 1024 * 1024) {
            throw Error('Choose a JPEG or PNG under 20 MB.');
        }
        const source = URL.createObjectURL(file);
        const picture = new Image();
        try {
            await new Promise((resolve, reject) => {
                picture.onload = resolve;
                picture.onerror = () => reject(Error('This image couldn’t be opened. Choose another screenshot.'));
                picture.src = source;
            });
            if (picture.naturalWidth * picture.naturalHeight > 25000000) throw Error('Choose an image under 25 megapixels.');
            const scale = Math.min(1, 1600 / Math.max(picture.naturalWidth, picture.naturalHeight));
            const canvas = document.createElement('canvas');
            canvas.width = Math.max(1, Math.round(picture.naturalWidth * scale));
            canvas.height = Math.max(1, Math.round(picture.naturalHeight * scale));
            const context = canvas.getContext('2d');
            context.fillStyle = 'white';
            context.fillRect(0, 0, canvas.width, canvas.height);
            context.drawImage(picture, 0, 0, canvas.width, canvas.height);
            const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg', .85));
            if (!blob) throw Error('This image couldn’t be prepared. Choose another screenshot.');
            if (blob.size > 2 * 1024 * 1024) throw Error('This receipt is too large. Choose a smaller image.');
            return await new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = () => resolve(reader.result);
                reader.onerror = () => reject(Error('This image couldn’t be opened. Choose another screenshot.'));
                reader.readAsDataURL(blob);
            });
        } finally {
            URL.revokeObjectURL(source);
        }
    }

    byId('file').onchange = async () => {
        image = null;
        byId('preview').hidden = true;
        byId('file-label').textContent = 'Choose a payment screenshot';
        const file = byId('file').files[0];
        lock(true);
        try {
            if (!file) return;
            notice('Preparing your screenshot…');
            const encoded = await prepareImage(file);
            image = encoded.split(',')[1];
            byId('preview').src = encoded;
            byId('preview').hidden = false;
            byId('file-label').textContent = 'Choose a different screenshot';
            notice('');
        } catch (error) { notice(error.message); }
        finally { lock(false); }
    };

    function upload() {
        return new Promise((resolve, reject) => {
            const request = new XMLHttpRequest();
            request.open('POST', '/v2/guest/receipts');
            request.timeout = 90000;
            request.setRequestHeader('Content-Type', 'application/json');
            request.setRequestHeader('Authorization', 'Checkout ' + capability);
            request.upload.onprogress = event => {
                if (event.lengthComputable) byId('progress').value = Math.round(100 * event.loaded / event.total);
            };
            request.upload.onload = () => {
                byId('progress').removeAttribute('value');
                notice('Saving your receipt…');
            };
            request.onload = () => {
                let response;
                try { response = JSON.parse(request.responseText); } catch { /* Treat an unreadable response as uncertain. */ }
                if (request.status >= 200 && request.status < 300 && response?.submitted === true) resolve();
                else reject(Error(response?.message || 'We couldn’t confirm the upload.'));
            };
            request.onerror = request.ontimeout = () => reject(Error('We couldn’t confirm the upload.'));
            request.send(JSON.stringify({ snapshotHash: checkout.snapshotHash, mimeType: 'image/jpeg', base64: image, confirmsTransfer: true }));
        });
    }

    byId('upload').onclick = async () => {
        if (!checkout || !image || busy) return;
        lock(true);
        byId('progress').value = 0;
        byId('progress').hidden = false;
        notice('Uploading your receipt…');
        try {
            await upload();
            showReceiptReceived();
        } catch (error) {
            try { checkout = await readStatus(); } catch { /* The original image stays available for retry. */ }
            if (checkout.receipt?.submitted) showReceiptReceived();
            else notice(error.message + ' Check status or retry the same screenshot.', { retry: true });
        } finally {
            byId('progress').hidden = true;
            lock(false);
        }
    };

    refresh();
})();
</script>
</body>
</html>`;
}
