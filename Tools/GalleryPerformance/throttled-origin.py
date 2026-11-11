#!/usr/bin/env python3
"""Loopback-only synthetic origin for real TCP backlog/byte-loss measurements."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import threading
import time
from urllib.parse import urlsplit, parse_qs


class Origin:
    lock = threading.RLock()
    def reset(self, config):
        with self.lock:
            self.config = config
            self.started = time.monotonic()
            self.next_byte_time = self.started
            self.bytes = 0
            self.control_bytes = 0
            self.assets = {}
            self.galleries = {}
            self.publications = {}
            self.dropped = False
    def pace(self, count):
        with self.lock:
            rate = self.config.get('mbps', 0)
            if self.config.get('improveAfter') and time.monotonic()-self.started >= self.config['improveAfter']:
                rate = 0
            if not rate:
                return
            due = max(time.monotonic(), self.next_byte_time) + count/(rate*1000000/8)
            self.next_byte_time = due
        time.sleep(max(0, due-time.monotonic()))


origin = Origin()
origin.reset({})


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # URLs and request bodies never enter benchmark logs.
    def setup(self):
        super().setup()
        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
    def reply(self, body, code=200, headers=None):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        for key,value in (headers or {}).items():
            self.send_header(key,value)
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True
    def do_GET(self):
        path = urlsplit(self.path)
        if path.path == '/stats':
            with origin.lock:
                self.reply({'actualBodyBytesRead':origin.bytes,'publications':sum(origin.publications.values()),
                    'controlBodyBytesRead':origin.control_bytes,
                    'duplicatePublications':sum(max(0,n-1) for n in origin.publications.values()),'elapsedSeconds':time.monotonic()-origin.started})
        elif path.path == '/diagnostic':
            self.reply({'uploadTransports':['drive-resumable-v1']})
        elif path.path == '/status':
            token = parse_qs(path.query).get('g',[''])[0]
            with origin.lock:
                gallery = origin.galleries.get(token)
                if gallery and origin.publications.get(token):
                    self.reply({'statusVersion':1,'ok':True,'status':'complete','galleryToken':token,
                        'sessionID':gallery['sessionID'],'schemaVersion':gallery['schemaVersion'],
                        'fileCount':len(gallery['photos'])+2})
                else:
                    self.reply({'statusVersion':1,'ok':False,'status':'unavailable'})
        else:
            self.reply({},404)
    def read_body(self, paced):
        remaining = int(self.headers.get('Content-Length','0'))
        if remaining > 10*1024*1024:
            raise ValueError('Synthetic request exceeds fixture bound')
        body = bytearray()
        while remaining:
            chunk = self.rfile.read(min(16384,remaining))
            if not chunk:
                break
            if paced:
                origin.pace(len(chunk))
                with origin.lock:
                    origin.bytes += len(chunk)
            body.extend(chunk)
            remaining -= len(chunk)
        return bytes(body)
    def do_POST(self):
        if self.path == '/reset':
            origin.reset(json.loads(self.read_body(False)))
            self.reply({'ok':True})
            return
        # Control metadata is counted separately from media pacing; this fixture
        # models an upstream bottleneck, not Google/Apps Script processing latency.
        if self.path == '/coordinate':
            raw = self.read_body(True)
            with origin.lock:
                origin.control_bytes += len(raw)
            body = json.loads(raw)
            token = body['galleryToken']
            with origin.lock:
                origin.galleries[token] = body
                images = body['photos']+[body['colorReceipt']]
                if body['action'] == 'finalize':
                    for image in images:
                        data = origin.assets.get((token,image['filename']),b'')
                        if len(data) != image['bytes'] or hashlib.sha256(data).hexdigest() != image['sha256']:
                            self.reply({'ok':False,'status':'retryable','errorCode':'ASSETS_INCOMPLETE'})
                            return
                    origin.publications[token] = max(1,origin.publications.get(token,0))
                    self.reply(self.completed(body))
                    return
                assets = []
                for image in images:
                    stored = len(origin.assets.get((token,image['filename']),b'')) == image['bytes']
                    assets.append(dict(image,stored=stored,uploadURL='https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id='+token+'.'+image['filename']))
                self.reply({'ok':True,'transport':'drive-resumable-v1','galleryToken':token,'status':'transferring','assets':assets})
            return
        body = json.loads(self.read_body(True))
        token = body['galleryToken']
        with origin.lock:
            origin.galleries[token] = body
            for image in body['photos']+[body['colorReceipt']]:
                origin.assets[(token,image['filename'])] = base64.b64decode(image['base64Data'])
            origin.publications[token] = max(1,origin.publications.get(token,0))
        self.reply(self.completed(body))
    def completed(self, body):
        return {'ok':True,'transport':'drive-resumable-v1','schemaVersion':body['schemaVersion'],
            'galleryToken':body['galleryToken'],'galleryURL':'https://venue.synthetic.test/?g='+body['galleryToken'],
            'fileCount':len(body['photos'])+2,'status':'created'}
    def do_PUT(self):
        session = parse_qs(urlsplit(self.path).query)['upload_id'][0]
        token,name = session.split('.',1)
        content_range = self.headers['Content-Range']
        total = int(content_range.split('/')[-1])
        body = self.read_body(not content_range.startswith('bytes */'))
        with origin.lock:
            key = token,name
            existing = origin.assets.get(key,b'')
            if not content_range.startswith('bytes */'):
                start = int(content_range[6:].split('-')[0])
                if start != len(existing):
                    self.reply({},409)
                    return
                origin.assets[key] = existing+body
                if origin.config.get('loseChunkAck') and not origin.dropped:
                    origin.dropped = True
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
            count = len(origin.assets.get(key,b''))
            if count == total:
                self.reply({'size':total})
            else:
                self.reply({},308,{'Range':'bytes=0-'+str(count-1)} if count else {})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
    args.config.parent.mkdir(parents=True,exist_ok=True)
    args.config.write_text(json.dumps({'port':server.server_port}))
    server.serve_forever()
