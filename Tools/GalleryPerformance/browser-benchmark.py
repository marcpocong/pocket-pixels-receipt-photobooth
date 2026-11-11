"""Pace synthetic gzip HTML over loopback and measure a real 390×844 macOS WebKit view.

No origin latency, mobile CPU emulation, cellular radio, or customer content is modeled.
Requires macOS/Xcode (Apple frameworks only). Output and probe binary stay in fixture dir.
"""
import argparse
import gzip
import http.server
import json
import pathlib
import subprocess
import sys
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('fixtures', type=pathlib.Path)
parser.add_argument('--profiles', nargs='+', choices=['typical','slow'], default=['typical','slow'])
parser.add_argument('--counts', nargs='+', type=int, choices=[1,3,6], default=[1,3,6])
args = parser.parse_args()
root = args.fixtures.resolve()
probe = root / 'browser-probe'
subprocess.run(['swiftc', str(pathlib.Path(__file__).with_name('browser-probe.swift')),
                '-o', str(probe)], check=True)
profiles = {'typical': 8_000_000 / 8, 'slow': 1_600_000 / 8}
bodies = {n: gzip.compress((root / f'gallery-{n}.html').read_bytes(), mtime=0)
          for n in [1, 3, 6]}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        try:
            _, profile, count = self.path.split('/')
            rate, body = profiles[profile], bodies[int(count)]
        except (ValueError, KeyError):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Encoding', 'gzip')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        started = time.monotonic()
        try:
            for offset in range(0, len(body), 8192):
                self.wfile.write(body[offset:offset + 8192])
                self.wfile.flush()
                time.sleep(max(0, started + (offset + 8192) / rate - time.monotonic()))
        except (BrokenPipeError, ConnectionResetError):
            pass


def web_content_processes():
    """RSS for new macOS WebContent processes; excludes iOS simulator helpers."""
    rows = subprocess.check_output(['ps', '-axo', 'pid=,rss=,comm='], text=True)
    return {int(pid): int(rss) * 1024
            for line in rows.splitlines() if 'WebKit.WebContent' in line
            for pid, rss, command in [line.strip().split(None, 2)]
            if command.startswith('/System/')}


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
results = []
try:
    for profile in args.profiles:
        for count in args.counts:
            output = root / f'{profile}-{count}.json'
            prior = web_content_processes()
            peak_rss = 0
            process = subprocess.Popen([str(probe),
                f'http://127.0.0.1:{server.server_port}/{profile}/{count}', str(output)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 85
            while process.poll() is None:
                current = web_content_processes()
                peak_rss = max(peak_rss, sum(rss for pid, rss in current.items() if pid not in prior))
                if time.monotonic() > deadline:
                    process.kill()
                    raise TimeoutError('Browser probe did not finish')
                time.sleep(.2)
            if process.returncode:
                raise RuntimeError('Browser probe failed')
            result = json.loads(output.read_text())
            if result.get('error') or result.get('firstPhotoMs') is None:
                raise RuntimeError(f'Invalid browser result: {profile}/{count}')
            result.update(profile=profile, photos=count,
                          htmlBytes=(root / f'gallery-{count}.html').stat().st_size,
                          gzipBytes=len(bodies[count]), newWebContentPeakRssBytes=peak_rss or None)
            results.append(result)
            print(json.dumps(result), flush=True)
    (root / 'results.json').write_text(json.dumps(results, indent=2))
finally:
    server.shutdown()
