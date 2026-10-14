#!/usr/bin/env python3
"""Compare local development apps using the same fixtures and native probe.
Requires macOS Command Line Tools, Python 3, and ad-hoc development apps.
No Xcode build, GitHub call, dependency installation, or cloud runner is used.
"""
import argparse
import json
import os
import plistlib
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def helpers():
    output = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
    result = {}
    for line in output.splitlines():
        if '/com.apple.WebKit.' in line:
            pid, name = line.strip().split(None, 1)
            result[int(pid)] = name
    return result

def memory(pid, allow_gone=False):
    info = subprocess.run(['vmmap', '-summary', str(pid)], capture_output=True, text=True, timeout=5)
    match = re.search(r'^Physical footprint:\s+([\d.]+)([KMG])', info.stdout, re.M)
    if not match:
        if allow_gone and ('no longer appears' in info.stderr or 'not running' in info.stderr): return None
        raise RuntimeError(f'Cannot measure PID {pid}: {info.stderr}')
    value, unit = match.groups()
    return float(value) * {'K': 1/1024, 'M': 1, 'G':1024}[unit]

def fixture(directory, sections):
    content = '# Benchmark café 😀\n\n![Relative image](image.svg)\n\n```javascript\nconst answer = 42;\n```\n\n- [x] Complete\n\n'
    content += ''.join(f'## Section {i}\n\nSome **bold** text and a [link](https://example.com).\n\n- First item\n- Second item\n\n' for i in range(sections))
    content += '\nPERFMARKER0\n'
    path = directory / f'document-{sections}.md'
    path.write_text(content)
    (directory/'image.svg').write_text("<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24'><rect width='24' height='24' fill='red'/></svg>")
    (directory/'tall.svg').write_text("<svg xmlns='http://www.w3.org/2000/svg' width='24' height='192'><rect width='24' height='192' fill='blue'/></svg>")
    return path

def benchmark(app, path, dylib, folder, label):
    output = folder / f'{label}.json'
    log_path = folder / f'{label}.log'
    env = os.environ.copy()
    env.update(DYLD_INSERT_LIBRARIES=str(dylib), MACDOWN_BENCHMARK_DOCUMENT=str(path), MACDOWN_BENCHMARK_OUTPUT=str(output))
    before = helpers()
    with log_path.open('w') as log:
        process = subprocess.Popen([str(app/'Contents/MacOS/MacDown'), '-ApplePersistenceIgnoreState', 'YES'], env=env, stdout=log, stderr=log)
        print(f'{label}: running PID {process.pid}', flush=True)
        limit = time.monotonic()+120
        snapshots = {}
        try:
            while process.poll() is None:
                if time.monotonic() > limit:
                    raise TimeoutError(f'{label}: exceeded 120 seconds')
                for stage, signal in [('loaded','BENCHMARK_MEMORY_READY'),('edited','BENCHMARK_MEMORY_AFTER_EDITS'),('closed','BENCHMARK_MEMORY_CLOSED')]:
                    if stage in snapshots or signal not in log_path.read_text(errors='replace'):continue
                    time.sleep(.3) # Let the current main-run-loop autorelease pool drain.
                    created = {pid:name for pid,name in helpers().items() if pid not in before}
                    measured=[]
                    for pid,name in created.items():
                        amount=memory(pid,allow_gone=True)
                        if amount is not None:measured.append({'pid':pid,'name':name,'mib':amount})
                    snapshot = {'app_mib':memory(process.pid), 'helpers':measured}
                    snapshot['total_mib'] = snapshot['app_mib'] + sum(p['mib'] for p in snapshot['helpers'])
                    snapshots[stage] = snapshot
                time.sleep(.1)
            if process.returncode or not output.exists():
                raise RuntimeError(f'{label} failed (exit {process.returncode}):\n{log_path.read_text(errors="replace")[-7000:]}')
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill();process.wait()
    result = json.loads(output.read_text())
    with (app/'Contents/Info.plist').open('rb') as stream: info=plistlib.load(stream)
    result['build_info']={key:info[key] for key in info if key.startswith('MPSource') or key.startswith('MPCompiledResources')}
    times = result['edit_dom_ready_ms']
    result.update(label=label, app=str(app), fixture_bytes=path.stat().st_size,
                  median_edit_ms=statistics.median(times), p95_edit_ms=sorted(times)[int(.95*(len(times)-1))],
                  memory=snapshots)
    output.write_text(json.dumps(result, indent=2)+'\n')
    print(f"{label}: median {result['median_edit_ms']:.1f} ms, p95 {result['p95_edit_ms']:.1f} ms, {snapshots['edited']['total_mib']:.1f} MiB after edits, {result['edit_navigations']} navigations", flush=True)
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apps', nargs='+', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'Artifacts/PreviewComparison')
    parser.add_argument('--sections', nargs='+', type=int, default=[10,1000])
    parser.add_argument('--repeats', type=int, default=2)
    args = parser.parse_args()
    args.output = args.output.resolve(); args.output.mkdir(parents=True, exist_ok=True)
    dylib = args.output/'preview-benchmark.dylib'
    run('xcrun','clang','-dynamiclib','-fobjc-arc','-fno-modules','-undefined','dynamic_lookup',
        '-I'+str(ROOT/'MacDown/Code/Document'),'-framework','Cocoa','-framework','WebKit',
        str(ROOT/'Tests/Native/preview-benchmark.m'),'-o',str(dylib))
    run('codesign','--force','--sign','-',str(dylib))
    results = []
    with tempfile.TemporaryDirectory(prefix='macdown-fixture-') as temporary:
        for sections in args.sections:
            path = fixture(Path(temporary), sections)
            for repetition in range(args.repeats):
                # Reverse order on alternating repetitions to reduce warm-cache bias.
                apps = list(enumerate(args.apps))
                if repetition%2: apps.reverse()
                for index,app in apps:
                    label = f'app{index+1}-{sections}-r{repetition+1}'
                    results.append(benchmark(app.resolve(), path, dylib, args.output, label))
    for sections in args.sections:
        for repetition in range(args.repeats):
            group=[r for r in results if r['label'].endswith(f'-{sections}-r{repetition+1}')]
            for compared in group[1:]:
                if compared['editor_heading_positions']!=group[0]['editor_heading_positions']:
                    raise RuntimeError('Scroll geometry differs between app variants')
    (args.output/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('Results:',args.output/'results.json')

if __name__=='__main__':
    main()
