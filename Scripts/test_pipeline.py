#!/usr/bin/env python3
"""Reusable portable, built-app, and full-Xcode test pipeline."""
import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import statistics
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
PYTHON = sys.executable
FUNCTIONAL_CHECKS = ('rapid_edits_latest_only', 'custom_script_fallback', 'language_change',
                     'inline_event_fallback', 'image_geometry_refresh',
                     'explicit_refresh_navigation', 'print_operation')
EDITING_CHECKS = {
    'precise_selection_and_inactive_editor_highlight', 'native_keyboard_input_and_document_save',
    'native_ime_composition', 'rapid_preview_typing_preserves_markdown', 'native_undo', 'native_redo',
    'unicode_selection_and_edit', 'literal_paste_and_link_destination', 'isolated_mutation_bridge',
    'stale_preview_mutation_rejected', 'return_and_typing_in_new_paragraph',
    'return_continues_list_and_preserves_caret', 'native_backspace_preserves_formatting',
    'formatted_paragraph_split_and_rapid_input', 'highlighted_code_edit_preserves_fence',
    'code_indentation_deletes_one_character', 'table_cell_edit_preserves_structure',
    'typing_in_empty_document', 'typing_across_render_refreshes',
    'generated_html_fails_closed_safe_blocks_still_editable', 'invalid_ranges_rejected',
}


def expected_xctests():
    expected = set()
    for path in (ROOT / 'MacDownTests').glob('*.m'):
        source = path.read_text()
        for cls in re.findall(r'@interface\s+(\w+)\s*:\s*XCTestCase\b', source):
            implementation = re.search(r'@implementation\s+' + cls + r'\b(.*?)@end', source, re.S)
            if implementation:
                expected.update(cls + ' ' + name for name in re.findall(r'-\s*\(void\)\s*(test\w+)', implementation.group(1)))
    if not expected:
        raise ValueError('No XCTest cases found in source')
    return expected


def assess_xctests(log, expected):
    passed = set(' '.join(match) for match in re.findall(r"Test Case '-\[(\w+) (test\w+)\]' passed", log))
    missing = expected - passed
    if missing:
        raise ValueError('XCTest did not pass every source test: ' + ', '.join(sorted(missing)))
    return sorted(passed)


def number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(f'Invalid or missing measurement: {name}')
    return value


def assess_performance(results, budgets, candidate=1, repeats=1):
    """Require complete small/large runs; gate the candidate, not the comparison app."""
    metrics, failures = [], []
    for sections in (10, 1000):
        groups = {}
        for index in range(1, candidate + 1):
            labels = {f'app{index}-{sections}-r{r}' for r in range(1, repeats + 1)}
            rows = [row for row in results if row.get('label') in labels]
            if {row['label'] for row in rows} != labels or len(rows) != repeats:
                raise ValueError(f'Incomplete benchmark runs for app {index}, {sections} sections')
            for row in rows:
                for check in FUNCTIONAL_CHECKS:
                    if row.get(check) is not True:
                        raise ValueError(f"{row['label']}: missing functional check {check}")
                if len(row.get('edit_dom_ready_ms', [])) != 20:
                    raise ValueError(f"{row['label']}: expected 20 timed edits after warmup")
                for value in row['edit_dom_ready_ms']:
                    number(value, 'edit sample')
                for state in ('loaded', 'edited', 'closed'):
                    if number(row.get('memory', {}).get(state, {}).get('total_mib'), state + ' memory') <= 0:
                        raise ValueError(f"{row['label']}: missing {state} memory sample")
            groups[index] = rows
        rows = groups[candidate]
        values = {
            'median_edit_ms': statistics.median(number(r.get('median_edit_ms'), 'median_edit_ms') for r in rows),
            'p95_edit_ms': max(number(r.get('p95_edit_ms'), 'p95_edit_ms') for r in rows),
            'edited_total_mib': statistics.median(number(r.get('memory', {}).get('edited', {}).get('total_mib'), 'edited memory') for r in rows),
            'closed_total_mib': statistics.median(number(r.get('memory', {}).get('closed', {}).get('total_mib'), 'closed memory') for r in rows),
            'edit_navigations': max(number(r.get('edit_navigations'), 'edit_navigations') for r in rows),
        }
        for key, value in values.items():
            if value > number(budgets.get(key), key):
                failures.append(f'{sections} sections: {key} {value:.1f} exceeds {budgets[key]}')
        for row in rows:
            retained = row.get('retained_nodes', {})
            if not all(retained.get(key) is True for key in ('page', 'image', 'code', 'tasks')) or retained.get('tokens', 0) <= 0:
                failures.append(f"{row['label']}: page/image/code retention or highlighting failed")
        if candidate == 2:
            baseline = groups[1]
            latency = statistics.median(number(r.get('median_edit_ms'), 'baseline latency') for r in baseline)
            memory = statistics.median(number(r.get('memory', {}).get('edited', {}).get('total_mib'), 'baseline memory') for r in baseline)
            if values['median_edit_ms'] > latency * budgets['baseline_latency_ratio'] + budgets['baseline_latency_slack_ms']:
                failures.append(f'{sections} sections: latency regressed against the comparison app')
            if values['edited_total_mib'] > memory * budgets['baseline_memory_ratio'] + budgets['baseline_memory_slack_mib']:
                failures.append(f'{sections} sections: memory regressed against the comparison app')
            values['baseline_median_edit_ms'], values['baseline_edited_total_mib'] = latency, memory
        metrics.append({'sections': sections, **values})
    return metrics, failures


class Pipeline:
    def __init__(self, output, profile):
        self.output = output
        self.output.mkdir(parents=True, exist_ok=False)
        state = subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).splitlines()
        self.report = {'profile': profile, 'status': 'running', 'stages': [], 'metrics': [],
                       'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                       'dirty': bool(state), 'worktree_changes': state,
                       'host': {'system': platform.system(), 'machine': platform.machine(), 'macos': platform.mac_ver()[0]}}
        self.save()

    def save(self):
        (self.output / 'results.json').write_text(json.dumps(self.report, indent=2) + '\n')

    def stage(self, name, command, timeout=300):
        start = time.monotonic()
        log = self.output / f'{name}.log'
        stage = {'name': name, 'status': 'running', 'log': log.name}
        self.report['stages'].append(stage)
        self.save()
        print(f'Running {name}…', flush=True)
        try:
            with log.open('w') as stream:
                process = subprocess.Popen([str(arg) for arg in command], cwd=ROOT, stdout=stream,
                                           stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    result = process.wait(timeout=timeout)
                except (subprocess.TimeoutExpired, KeyboardInterrupt):
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    raise
                if result:
                    raise subprocess.CalledProcessError(result, command)
            stage['status'] = 'passed'
        except (subprocess.SubprocessError, OSError, KeyboardInterrupt):
            stage['status'] = 'failed'
            print(log.read_text(errors='replace')[-10000:], file=sys.stderr)
            raise
        finally:
            stage['seconds'] = round(time.monotonic() - start, 2)
            self.save()

    def finish(self, status, error=None):
        self.report['status'] = status
        if error:
            self.report['error'] = str(error)
            print(str(error), file=sys.stderr, flush=True)
        self.save()
        text = [f'# MacDown tests: {status}', '', f"Source: `{self.report['commit']}`", '', '| Check | Result | Seconds |', '| --- | --- | ---: |']
        text += [f"| {s['name']} | {s['status']} | {s.get('seconds', '—')} |" for s in self.report['stages']]
        if self.report['metrics']:
            text += ['', '| Sections | Median ms | p95 ms | Edited MiB | Closed MiB |', '| ---: | ---: | ---: | ---: | ---: |']
            text += [f"| {m['sections']} | {m['median_edit_ms']:.1f} | {m['p95_edit_ms']:.1f} | {m['edited_total_mib']:.1f} | {m['closed_total_mib']:.1f} |" for m in self.report['metrics']]
        if error:
            text += ['', str(error)]
        summary = '\n'.join(text) + '\n'
        (self.output / 'summary.md').write_text(summary)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
                stream.write(summary)
        print(f'{status}: {self.output / "results.json"}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', choices=['portable', 'app', 'full'])
    parser.add_argument('--app', type=Path, help='Already built candidate app (app profile)')
    parser.add_argument('--baseline-app', type=Path, help='Optional earlier app, measured on this same host')
    parser.add_argument('--repeats', type=int, default=1)
    parser.add_argument('--output', type=Path, default=ROOT / 'Artifacts/Tests')
    parser.add_argument('--portable-checked', action='store_true', help='CI only: reuse this commit’s successful prerequisite Linux job')
    args = parser.parse_args()
    if args.repeats < 1 or args.profile == 'app' and not args.app:
        parser.error('Use positive repeats and supply --app for the app profile')
    if args.profile != 'app' and args.app or args.profile == 'portable' and args.baseline_app:
        parser.error('App paths require an app/full test profile')
    run_id = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    pipeline = Pipeline(args.output.resolve() / run_id, args.profile)
    stage = pipeline.stage
    try:
        if args.portable_checked:
            if args.profile != 'full' or os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('GITHUB_SHA') != pipeline.report['commit'] or pipeline.report['dirty']:
                raise ValueError('--portable-checked requires a clean, matching GitHub Actions commit and full profile')
            pipeline.report['stages'].append({'name': 'portable-prerequisite', 'status': 'passed', 'seconds': 0, 'source': 'Linux prerequisite job in this workflow'})
        else:
            stage('portable', ['bash', 'Scripts/check.sh'])
            stage('secrets', [PYTHON, 'Scripts/check-secrets.py', '--output', pipeline.output / 'secrets'])
        if args.profile != 'portable':
            from macos_test_support import require_desktop_access
            try:
                require_desktop_access()
            except SystemExit as error:
                pipeline.report['stages'].append({'name': 'desktop', 'status': 'blocked', 'seconds': 0})
                pipeline.finish('blocked', error)
                return 1
            pipeline.report['stages'].append({'name': 'desktop', 'status': 'passed', 'seconds': 0})
            if args.profile == 'full':
                stage('xcode-tests-and-build', ['bash', 'Scripts/build-macos.sh', '--portable-checked'], timeout=900)
                try:
                    pipeline.report['xctests_passed'] = assess_xctests(
                        (pipeline.output / 'xcode-tests-and-build.log').read_text(errors='replace'), expected_xctests())
                except ValueError:
                    pipeline.report['stages'][-1]['status'] = 'failed'
                    raise
                app = ROOT / 'Artifacts/MacDown.app'
            else:
                stage('toolbar', ['bash', 'Scripts/check-macos-local.sh', '--toolbar-only'])
                app = args.app.resolve()
            with (app / 'Contents/Info.plist').open('rb') as stream:
                info = plistlib.load(stream)
            pipeline.report['app'] = {key: info.get(key) for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleBuildVersion')}
            stage('bundle', [PYTHON, 'Scripts/verify-app.py', app])
            stage('signature', ['codesign', '--verify', '--deep', '--strict', app], timeout=60)
            stage('universal', ['lipo', app / 'Contents/MacOS/MacDown', '-verify_arch', 'arm64', 'x86_64'], timeout=15)
            stage('cli-universal', ['lipo', app / 'Contents/SharedSupport/bin/macdown', '-verify_arch', 'arm64', 'x86_64'], timeout=15)
            stage('cli', [app / 'Contents/SharedSupport/bin/macdown', '--version'], timeout=15)
            expected = f"version {info['CFBundleShortVersionString']} (build {info['CFBundleVersion']})"
            if expected not in (pipeline.output / 'cli.log').read_text():
                pipeline.report['stages'][-1]['status'] = 'failed'
                raise ValueError('CLI and app versions differ')
            stage('app-secrets', [PYTHON, 'Scripts/check-secrets.py', '--app', app, '--output', pipeline.output / 'app-secrets'])
            editing = pipeline.output / 'editing'
            stage('editing', [PYTHON, 'Scripts/check-preview-editing.py', app, '--output', editing], timeout=120)
            passed = json.loads((editing / 'results.json').read_text()).get('passed', [])
            if set(passed) != EDITING_CHECKS or len(passed) != len(EDITING_CHECKS):
                pipeline.report['stages'][-1]['status'] = 'failed'
                raise ValueError('Preview editing suite did not complete all 21 checks')
            apps = [app] if not args.baseline_app else [args.baseline_app.resolve(), app]
            benchmark = pipeline.output / 'benchmark'
            stage('renderer-and-performance', [PYTHON, 'Scripts/benchmark-preview.py', *apps, '--sections', '10', '1000', '--repeats', args.repeats, '--output', benchmark], timeout=2 * len(apps) * args.repeats * 125 + 30)
            budgets = json.loads((ROOT / 'Tests/performance-budgets.json').read_text())
            results = json.loads((benchmark / 'results.json').read_text())
            metrics, failures = assess_performance(results, budgets, candidate=len(apps), repeats=args.repeats)
            pipeline.report['metrics'], pipeline.report['budgets'] = metrics, budgets
            pipeline.report['stages'].append({'name': 'performance-budgets', 'status': 'failed' if failures else 'passed', 'seconds': 0})
            if failures:
                raise ValueError('; '.join(failures))
        pipeline.finish('passed')
        return 0
    except (Exception, KeyboardInterrupt) as error:
        pipeline.finish('failed', error)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
