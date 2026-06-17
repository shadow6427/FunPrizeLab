# Schemas

## `default-config.schema.json`

This schema describes the generated application configuration object used by
`tools/config_generator.py`. The source structure is `DEFAULT_CONFIG`, with the
same top-level sections that `generate_config()` returns after applying
environment overrides.

Example payloads live in `examples/config/`:

- `valid-development.json`
- `valid-production.json`
- `invalid-missing-app.json`

The invalid example intentionally omits the required `app` section.
