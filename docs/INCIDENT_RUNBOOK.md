# Incident Runbook

This runbook is for repository operators handling incidents in this codebase.
It ties local build diagnostics, service health checks, deployment history,
migration tooling, and OpenAPI contract checks into one response flow.

Use it with the current repository checkout from the project root. Commands
that touch staging or production still require the normal environment access
and change approval described in `docs/OPERATIONS.md`.

## First Response

1. Record the incident time, affected environment, service, and triggering
   alert.
2. Capture current health:

   ```bash
   python3 tools/health_check.py --json --output diagnostic/health-current.json
   python3 tools/health_check.py --service backend --json
   python3 tools/health_check.py --service market --json
   python3 tools/health_check.py --service frailbox --json
   ```

3. Run a repository build before changing anything:

   ```bash
   python3 build.py
   ```

   The build writes diagnostic metadata under `diagnostic/build-<commit>.json`
   and may write an encrypted `diagnostic/build-<commit>.logd`. A file named
   `diagnostic/build-00000000.logd` is only a stub and is not valid incident
   evidence or bounty payout evidence. Use the commit-specific file emitted by
   `build.py`, or include the JSON metadata explaining why `.logd` creation
   failed.

4. If the incident follows a deployment, inspect deployment history before
   taking rollback action:

   ```bash
   python3 tools/deploy.py --env staging --history
   python3 tools/deploy.py --env production --history
   ```

5. Keep all generated evidence together in the incident notes: health JSON,
   build diagnostic JSON, `.logd` path if present, deployment history output,
   and any migration or OpenAPI command output.

## Failed Build Diagnostics

Use this path when CI, local validation, or a bounty submission reports a
missing or failed diagnostic artifact.

1. List available modules and rerun the failing scope:

   ```bash
   python3 build.py --list
   python3 build.py --module backend --verbose
   python3 build.py --module frontend --verbose
   python3 build.py --module market --verbose
   python3 build.py --module frailbox --verbose
   ```

2. If the full build fails, keep the non-zero exit code as signal. Do not mark
   the build successful because one module produced an artifact.
3. Open `diagnostic/build-<commit>.json` and verify each failed module has an
   explicit failure status and captured output. If the JSON points to a
   `.logd`, include that path in the incident notes.
4. Ignore `diagnostic/build-00000000.logd` for incident conclusions. It is a
   checked-in placeholder, not a real diagnostic bundle from the current run.
5. Clean stale diagnostics only after evidence is copied into the incident:

   ```bash
   python3 build.py --clean
   ```

## Unhealthy Service Checks

Use this path when `/health`, Prometheus alerts, or synthetic checks report a
service as degraded.

1. Run all checks and capture JSON:

   ```bash
   python3 tools/health_check.py --json --output diagnostic/health-current.json
   ```

2. Narrow to the affected service:

   ```bash
   python3 tools/health_check.py --service backend --json
   python3 tools/health_check.py --service market --json
   python3 tools/health_check.py --service frailbox --json
   ```

3. Compare the service port and endpoint against the operations table in
   `docs/OPERATIONS.md`:

   - backend API: `localhost:8080/health`
   - market engine: `localhost:8081/health`
   - frailbox runtime: `localhost:8082/health`
   - frontend: `localhost:3000/`

4. If the affected environment is Kubernetes, collect pod state before restart:

   ```bash
   kubectl logs -n tent-production deployment/backend-api
   kubectl describe pod -n tent-production -l app=backend-api
   kubectl get deploy -n tent-production
   ```

5. Restart only after evidence capture and approval:

   ```bash
   kubectl rollout restart deployment/backend-api -n tent-production
   kubectl rollout status deployment/backend-api -n tent-production
   python3 tools/health_check.py --service backend --json
   ```

## Bad Deployment

Use this path when a release introduced errors, missing assets, or service
degradation.

1. Capture health and deployment history:

   ```bash
   python3 tools/health_check.py --json --output diagnostic/health-current.json
   python3 tools/deploy.py --env production --history
   ```

2. Confirm the intended service and tag from the history output. For legacy
   deployments, the script supports explicit service and tag inputs:

   ```bash
   python3 tools/deploy.py --env staging --service backend --tag v3.2.0
   python3 tools/deploy.py --env production --service all --tag v3.2.0
   ```

3. If rollback is required, prefer the last known good version recorded in
   deployment history:

   ```bash
   python3 tools/deploy.py --env production --rollback --version v3.1.0
   python3 tools/health_check.py --json --output diagnostic/health-after-rollback.json
   ```

4. If the GitOps path owns the environment, do not use the legacy deploy script
   to mutate production. Use the script only to inspect history and follow the
   GitOps rollback process for that environment.

## Migration Failure

Use this path when schema changes, seed data, or data migration steps fail.

1. Inspect current migration state:

   ```bash
   python3 tools/db_migration.py --status --env production
   python3 tools/legacy_migration.py status
   ```

2. Dry-run pending schema migrations before retrying:

   ```bash
   python3 tools/db_migration.py --up --dry-run --env staging
   ```

3. Apply pending migrations only after backup and approval:

   ```bash
   python3 tools/db_migration.py --up --env production
   ```

4. Roll back a known schema migration version with:

   ```bash
   python3 tools/db_migration.py --down --version 20240101000000 --env production
   ```

5. For legacy data migrations, preserve the backup directory and use the
   migration id from the failed run:

   ```bash
   python3 tools/legacy_migration.py rollback --migration-id MIG001
   python3 tools/legacy_migration.py validate --data-dir ./migration_output
   ```

6. After any migration action, rerun health checks and a build:

   ```bash
   python3 tools/health_check.py --json --output diagnostic/health-after-migration.json
   python3 build.py
   ```

## OpenAPI Contract Regression

Use this path when clients report missing routes, changed response shapes, or
contract test failures.

1. Compare the current spec against a previous or remote spec:

   ```bash
   lua tools/openapi_diff.lua --left docs/openapi/v3.yaml --right docs/openapi/v3.previous.yaml
   lua tools/openapi_diff.lua --local docs/openapi/v3.yaml --remote https://api.example.com/openapi.yaml
   lua tools/openapi_diff.lua --self docs/openapi/v3.yaml
   ```

2. Generate or validate consumer pacts:

   ```bash
   lua tools/openapi_pact.lua --validate
   lua tools/openapi_pact.lua --consumer web-app
   ```

3. Reproduce unexpected responses against a local mock when the live service is
   unstable:

   ```bash
   lua tools/openapi_mock.lua
   ```

4. Fuzz a suspected endpoint class only after setting an explicit target:

   ```bash
   lua tools/openapi_fuzz.lua --target https://api.example.com/v3 --iterations 1000 --spec docs/openapi/v3.yaml
   ```

5. If the regression came from a deployment, combine OpenAPI evidence with the
   bad deployment rollback path above.

## Closeout Checklist

- Incident record includes the failing command, exit code, and affected module
  or service.
- `python3 build.py` was run after the fix or rollback.
- Real diagnostic metadata from `diagnostic/build-<commit>.json` is attached.
- Any `.logd` evidence is commit-specific, not `build-00000000.logd`.
- Health check output before and after remediation is attached.
- Deployment, migration, and OpenAPI outputs are attached when those systems
  were part of the incident.
- Follow-up work is filed for any manual step, stale legacy command, or missing
  automation discovered during the response.
