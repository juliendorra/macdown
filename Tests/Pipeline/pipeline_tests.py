"""Regression gates must reject incomplete runs and real performance regressions."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts'))
from test_pipeline import FUNCTIONAL_CHECKS, Pipeline, assess_performance, assess_xctests, expected_xctests


def results(apps=1, repeats=1):
    rows = []
    for app in range(1, apps + 1):
        for sections in (10, 1000):
            for repeat in range(1, repeats + 1):
                rows.append({
                    'label': f'app{app}-{sections}-r{repeat}',
                    **{check: True for check in FUNCTIONAL_CHECKS},
                    'edit_dom_ready_ms': [200] * 20,
                    'median_edit_ms': 200, 'p95_edit_ms': 220, 'edit_navigations': 0,
                    'memory': {'loaded': {'total_mib': 120}, 'edited': {'total_mib': 155}, 'closed': {'total_mib': 70}},
                    'retained_nodes': {'page': True, 'image': True, 'code': True, 'tasks': True, 'tokens': 3},
                })
    return rows


class PerformanceTests(unittest.TestCase):
    def setUp(self):
        self.budgets = json.loads((ROOT / 'Tests/performance-budgets.json').read_text())

    def test_complete_runs_pass(self):
        metrics, failures = assess_performance(results(), self.budgets)
        self.assertEqual(failures, [])
        self.assertEqual([m['sections'] for m in metrics], [10, 1000])

    def test_missing_large_fixture_is_not_a_pass(self):
        with self.assertRaises(ValueError):
            assess_performance(results()[:1], self.budgets)

    def test_missing_functional_check_is_not_a_pass(self):
        rows = results()
        del rows[0]['image_geometry_refresh']
        with self.assertRaises(ValueError):
            assess_performance(rows, self.budgets)

    def test_missing_memory_is_not_a_pass(self):
        rows = results()
        del rows[0]['memory']['closed']
        with self.assertRaises(ValueError):
            assess_performance(rows, self.budgets)

    def test_navigation_and_memory_regressions_fail(self):
        rows = results()
        rows[1]['edit_navigations'] = 1
        rows[1]['memory']['edited']['total_mib'] = 600
        _, failures = assess_performance(rows, self.budgets)
        self.assertEqual(len(failures), 2)

    def test_nonfinite_measurement_is_rejected(self):
        rows = results()
        rows[0]['p95_edit_ms'] = float('nan')
        with self.assertRaises(ValueError):
            assess_performance(rows, self.budgets)

    def test_baseline_comparison_detects_regression_below_absolute_ceiling(self):
        rows = results(apps=2, repeats=2)
        for row in rows:
            if row['label'].startswith('app2-'):
                row['median_edit_ms'] = 300
                row['memory']['edited']['total_mib'] = 250
        _, failures = assess_performance(rows, self.budgets, candidate=2, repeats=2)
        self.assertEqual(len(failures), 4)

    def test_old_baseline_navigation_does_not_fail_optimized_candidate(self):
        rows = results(apps=2)
        rows[0]['edit_navigations'] = 22
        _, failures = assess_performance(rows, self.budgets, candidate=2)
        self.assertEqual(failures, [])

    def test_missing_repetition_is_rejected(self):
        with self.assertRaises(ValueError):
            assess_performance(results(), self.budgets, repeats=2)


class ReportTests(unittest.TestCase):
    def test_command_failure_is_saved_with_log_and_failed_summary(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': ''}):
            pipeline = Pipeline(Path(directory) / 'run', 'portable')
            with self.assertRaises(subprocess.CalledProcessError):
                pipeline.stage('failing-check', [sys.executable, '-c', "print('diagnostic'); raise SystemExit(7)"])
            pipeline.finish('failed', 'command failed')
            report = json.loads((pipeline.output / 'results.json').read_text())
            self.assertEqual(report['status'], 'failed')
            self.assertEqual(report['stages'][0]['status'], 'failed')
            self.assertIn('diagnostic', (pipeline.output / 'failing-check.log').read_text())
            self.assertTrue((pipeline.output / 'summary.md').is_file())

    def test_reusing_a_report_directory_cannot_pass_with_stale_results(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileExistsError):
                Pipeline(Path(directory), 'portable')

    def test_hung_check_times_out_and_records_failure(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            pipeline = Pipeline(Path(directory) / 'run', 'portable')
            with self.assertRaises(subprocess.TimeoutExpired):
                pipeline.stage('hung-check', [sys.executable, '-c', 'import time; time.sleep(30)'], timeout=0.1)
            report = json.loads((pipeline.output / 'results.json').read_text())
            self.assertEqual(report['stages'][0]['status'], 'failed')


class XCTestInventoryTests(unittest.TestCase):
    def test_inventory_contains_existing_preview_editing_regression(self):
        self.assertIn('MPPreviewTests testPreviewSelectionAndEditingPreserveMarkdown', expected_xctests())

    def test_a_skipped_test_cannot_count_as_a_pass(self):
        log = "Test Case '-[Example testOne]' passed (0.1 seconds).\nTest Case '-[Example testTwo]' skipped."
        with self.assertRaises(ValueError):
            assess_xctests(log, {'Example testOne', 'Example testTwo'})

    def test_all_required_cases_must_have_passed(self):
        log = "Test Case '-[Example testOne]' passed (0.1 seconds)."
        self.assertEqual(assess_xctests(log, {'Example testOne'}), ['Example testOne'])


if __name__ == '__main__':
    unittest.main()
