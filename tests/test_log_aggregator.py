import json
import os
import tempfile
import unittest
import sys
from pathlib import Path

# Add the tools directory to the path so we can import log_aggregator
sys.path.insert(0, str(Path(__file__).parent.parent / "tools"))

from log_aggregator import LogAggregator

class TestLogAggregator(unittest.TestCase):
    def setUp(self):
        self.aggregator = LogAggregator()
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_valid_json_log(self):
        log_content = '{"timestamp": 1704110400, "level": "info", "message": "Test"}\n'
        log_path = os.path.join(self.temp_dir.name, "valid.log")
        with open(log_path, 'w') as f:
            f.write(log_content)
        
        count = self.aggregator.process_file(log_path)
        self.assertEqual(count, 1)
        self.assertEqual(len(self.aggregator.parse_failures), 0)

    def test_malformed_json_log(self):
        # A malformed JSON line that will trigger JSONDecodeError
        log_content = '{"timestamp": 1704110400, "level": "info", "message": "Test"\n'
        log_path = os.path.join(self.temp_dir.name, "invalid.log")
        with open(log_path, 'w') as f:
            f.write(log_content)
        
        count = self.aggregator.process_file(log_path)
        self.assertEqual(count, 0)
        self.assertEqual(len(self.aggregator.parse_failures), 1)
        
        failure = self.aggregator.parse_failures[0]
        self.assertEqual(failure["file"], log_path)
        self.assertEqual(failure["line"], 1)
        self.assertEqual(failure["parser"], "JSONLogParser")
        self.assertIn("JSON Parse Error", failure["error"])

    def test_empty_lines_skipped(self):
        log_content = '\n\n'
        log_path = os.path.join(self.temp_dir.name, "empty.log")
        with open(log_path, 'w') as f:
            f.write(log_content)
            
        count = self.aggregator.process_file(log_path)
        self.assertEqual(count, 0)
        self.assertEqual(len(self.aggregator.parse_failures), 0)

    def test_export_parse_error_report(self):
        log_content = '{invalid}\n'
        log_path = os.path.join(self.temp_dir.name, "invalid.log")
        with open(log_path, 'w') as f:
            f.write(log_content)
            
        self.aggregator.process_file(log_path)
        
        report_path = os.path.join(self.temp_dir.name, "report.json")
        self.aggregator.export_parse_error_report(report_path)
        
        self.assertTrue(os.path.exists(report_path))
        with open(report_path, 'r') as f:
            report = json.load(f)
            
        self.assertEqual(report["total_failures"], 1)
        self.assertEqual(len(report["failures"]), 1)
        self.assertEqual(report["failures"][0]["parser"], "JSONLogParser")
        self.assertEqual(report["failures"][0]["line"], 1)

if __name__ == '__main__':
    unittest.main()
