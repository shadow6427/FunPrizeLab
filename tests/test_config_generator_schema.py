import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "tools" / "config_generator.py"


def load_module():
    spec = importlib.util.spec_from_file_location("config_generator", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_generated_default_config_is_valid():
    generator = load_module()
    config = generator.generate_config("production")

    assert generator.validation_errors(config, generator.CONFIG_SCHEMA) == []


def test_partial_input_schema_reports_all_errors():
    generator = load_module()
    fixture = Path(__file__).parent / "fixtures" / "config_invalid_types.json"
    data = generator.load_data_file(str(fixture))
    schema = generator.make_partial_schema(generator.CONFIG_SCHEMA)

    errors = generator.validation_errors(data, schema)

    assert len(errors) == 3
    assert any("app.debug" in error for error in errors)
    assert any("app.log_level" in error for error in errors)
    assert any("server.port" in error for error in errors)


def test_valid_override_merges_and_validates():
    generator = load_module()
    override = {
        "server": {"port": 9090},
        "features": {"ai_assistant": True},
    }

    config = generator.generate_config("staging", override)

    assert config["server"]["port"] == 9090
    assert config["features"]["ai_assistant"] is True
    assert generator.validation_errors(config, generator.CONFIG_SCHEMA) == []
