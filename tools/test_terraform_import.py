import unittest
from terraform_import import TerraformImporter, ResourceToImport

class TestTerraformImporter(unittest.TestCase):
    def setUp(self):
        self.importer = TerraformImporter()

    def test_valid_resource_name(self):
        res = ResourceToImport(resource_type="aws_instance", resource_name="web_server_1", resource_id="i-12345")
        is_valid, msg = self.importer.validate_resource(res)
        self.assertTrue(is_valid)
        self.assertEqual(msg, "")

    def test_hyphenated_resource_name(self):
        res = ResourceToImport(resource_type="aws_instance", resource_name="web-server-1", resource_id="i-12345")
        is_valid, msg = self.importer.validate_resource(res)
        self.assertFalse(is_valid)
        self.assertIn("Hyphenated names cause state corruption", msg)

    def test_invalid_terraform_identifier(self):
        res = ResourceToImport(resource_type="aws_instance", resource_name="123web", resource_id="i-12345")
        is_valid, msg = self.importer.validate_resource(res)
        self.assertFalse(is_valid)
        self.assertIn("Must be a valid Terraform identifier", msg)

    def test_import_batch_filters_invalid_names(self):
        resources = [
            ResourceToImport(resource_type="aws_instance", resource_name="valid_server", resource_id="i-111"),
            ResourceToImport(resource_type="aws_instance", resource_name="invalid-server", resource_id="i-222"),
        ]
        result = self.importer.import_batch(resources, dry_run=True)
        # Should have skipped 1 valid resource (dry run) and failed 1 invalid resource
        self.assertEqual(result.skipped_count, 1)
        self.assertEqual(result.failure_count, 1)
        self.assertEqual(len(result.results), 2)
        
        failed = [r for r in result.results if r["status"] == "validation_failed"]
        self.assertEqual(len(failed), 1)
        self.assertIn("invalid-server", failed[0]["address"])

    def test_generate_script_raises_on_invalid(self):
        resources = [
            ResourceToImport(resource_type="aws_instance", resource_name="invalid-server", resource_id="i-222"),
        ]
        with self.assertRaises(ValueError):
            self.importer.generate_import_script(resources, output_file="dummy.sh")

if __name__ == "__main__":
    unittest.main()
