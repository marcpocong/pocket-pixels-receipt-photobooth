#!/usr/bin/env python3
"""Run the manual real-TCP recovery benchmark without adding it to every CI run."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device-id',required=True,help='Available iPad simulator UDID')
parser.add_argument('--profiles',nargs='+',default=['strong20','strong50','strong100','weak20','improved20','interrupted50'])
parser.add_argument('--derived-data',default=str(Path.home()/'Library/Caches/PocketPixelsBooth/GalleryReliability'))
args=parser.parse_args()
config=root/'DerivedData/gallery-network-config.json'
config.parent.mkdir(exist_ok=True)
config.unlink(missing_ok=True)
target=root/'PocketPixelsBoothTests/ManualBacklogBenchmarks.swift'
if target.exists():raise SystemExit('Refusing to overwrite existing benchmark source')
server=subprocess.Popen([sys.executable,str(Path(__file__).with_name('throttled-origin.py')),'--config',str(config)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
try:
    for _ in range(100):
        if config.exists():break
        if server.poll() is not None:raise RuntimeError('Loopback fixture failed to start')
        time.sleep(.05)
    settings=json.loads(config.read_text());settings['profiles']=args.profiles;config.write_text(json.dumps(settings))
    shutil.copyfile(Path(__file__).with_name('ManualBacklogBenchmarks.swift'),target)
    command=['xcodebuild','test','-project','PocketPixelsBooth.xcodeproj','-scheme','PocketPixelsBooth','-destination','platform=iOS Simulator,id='+args.device_id,
        '-derivedDataPath',args.derived_data,'-parallel-testing-enabled','NO','-only-testing:PocketPixelsBoothTests/ManualBacklogBenchmarks',
        '-test-timeouts-enabled','YES','-default-test-execution-time-allowance','1800','-maximum-test-execution-time-allowance','1800',
        'CODE_SIGN_IDENTITY=-','CODE_SIGN_STYLE=Manual','DEVELOPMENT_TEAM=','PROVISIONING_PROFILE_SPECIFIER=']
    result=subprocess.run(command,cwd=root)
    raise SystemExit(result.returncode)
finally:
    server.terminate();server.wait(timeout=10)
    target.unlink(missing_ok=True)
    config.unlink(missing_ok=True)
