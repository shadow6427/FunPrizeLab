# Incident Runbook

This runbook ties together health checks, deployment history, diagnostics, and rollback/migration tooling for common operational failures specific to this repository.

## Failed Build Diagnostics

When a build fails, diagnostic logs are generated to help identify the root cause.
- Run `python3 build.py` locally to generate diagnostics.
- Review the generated log `diagnostic/build-XXX.logd` and `diagnostic/build-XXX.json`.
- **Note on Payouts**: `diagnostic/build-00000000.logd` is a stub and is **not valid payout evidence**. You must provide a real diagnostic log.

## Unhealthy Service Checks

If a service is reported as degraded:
- Run health checks locally against all services:
  ```bash
  python3 tools/health_check.py
  ```
- To check a specific service:
  ```bash
  python3 tools/health_check.py --service backend
  ```

## Bad Deployment & Rollback

If a recent deployment causes issues, review the deployment history and rollback.
- View deployment history:
  ```bash
  python3 tools/deploy.py --list
  ```
- Rollback to the previous stable version:
  ```bash
  python3 tools/deploy.py --rollback --version <VERSION>
  ```

## Migration Failure

If a database migration fails:
- Check migration status:
  ```bash
  python3 tools/db_migration.py --status
  ```
- Rollback the last applied migration:
  ```bash
  python3 tools/db_migration.py --down --version <VERSION>
  ```

## OpenAPI Contract Regression

If API consumers report broken contracts:
- Verify the current API schema against the known good baseline:
  ```bash
  lua tools/openapi_diff.lua --left <baseline_schema.yaml> --right <current_schema.yaml>
  ```
