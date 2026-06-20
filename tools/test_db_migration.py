import unittest
from unittest.mock import patch
import json
from io import StringIO
import sys

# Add current dir to sys.path so we can import db_migration
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db_migration

class TestMigrationStatus(unittest.TestCase):
    
    @patch('db_migration.get_disk_migrations')
    @patch('db_migration.get_db_migrations')
    def test_clean_state(self, mock_db, mock_disk):
        mock_disk.return_value = [
            {"version": "20210101000000", "description": "Initial schema", "type": "sql"}
        ]
        mock_db.return_value = [
            {"version": "20210101000000", "description": "Initial schema", "applied": True}
        ]
        
        status = db_migration.get_migration_status()
        # Should be clean since db matches disk (ignoring MIGRATIONS array for this isolated test)
        # Wait, MIGRATIONS array is hardcoded in db_migration.py, so it will add those!
        # Let's just check if the explicit ones have the correct state.
        
        my_status = next(s for s in status if s["version"] == "20210101000000")
        self.assertEqual(my_status["state"], "applied")
        
    @patch('db_migration.get_disk_migrations')
    @patch('db_migration.get_db_migrations')
    def test_pending_state(self, mock_db, mock_disk):
        mock_disk.return_value = [
            {"version": "20210101000000", "description": "Initial schema", "type": "sql"},
            {"version": "99999999999998", "description": "Future pending migration", "type": "sql"}
        ]
        mock_db.return_value = [
            {"version": "20210101000000", "description": "Initial schema", "applied": True}
        ]
        
        status = db_migration.get_migration_status()
        pending_migration = next(s for s in status if s["version"] == "99999999999998")
        self.assertEqual(pending_migration["state"], "pending")
        
    @patch('db_migration.get_disk_migrations')
    @patch('db_migration.get_db_migrations')
    def test_inconsistent_state(self, mock_db, mock_disk):
        mock_disk.return_value = [
            {"version": "20210101000000", "description": "Initial schema", "type": "sql"}
        ]
        # In DB but not on disk
        mock_db.return_value = [
            {"version": "20210101000000", "description": "Initial schema", "applied": True},
            {"version": "99999999999999", "description": "Missing on disk", "applied": True}
        ]
        
        status = db_migration.get_migration_status()
        
        missing_migration = next(s for s in status if s["version"] == "99999999999999")
        self.assertEqual(missing_migration["state"], "missing")
        
    @patch('db_migration.get_migration_status')
    @patch('sys.stdout', new_callable=StringIO)
    def test_cmd_status_json_clean(self, mock_stdout, mock_status):
        mock_status.return_value = [
            {"version": "20210101000000", "description": "Initial schema", "state": "applied", "applied": True}
        ]
        
        ret = db_migration.cmd_status(json_output=True)
        self.assertEqual(ret, 0)
        
        output = json.loads(mock_stdout.getvalue())
        self.assertEqual(len(output), 1)
        self.assertEqual(output[0]["state"], "applied")
        
    @patch('db_migration.get_migration_status')
    @patch('sys.stdout', new_callable=StringIO)
    def test_cmd_status_json_inconsistent(self, mock_stdout, mock_status):
        mock_status.return_value = [
            {"version": "20210101000000", "description": "Initial schema", "state": "applied", "applied": True},
            {"version": "99999999999999", "description": "Missing on disk", "state": "missing", "applied": False}
        ]
        
        ret = db_migration.cmd_status(json_output=True)
        self.assertEqual(ret, 1)

if __name__ == '__main__':
    unittest.main()
