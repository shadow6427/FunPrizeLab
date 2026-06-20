# Incident Runbook

This runbook is the repository-local checklist for common Tent of Trials
incidents. It intentionally references tools that live in this repository so an
operator can collect evidence, identify the faulty subsystem, and choose a safe
rollback or mitigation path without relying on generic SRE steps.

## Required Evidence

Start every incident by capturing the current revision and a real diagnostic
bundle:

```sh
git rev-parse --short=8 HEAD
python3 build.py
ls -lh diagnostic/build-*.logd diagnostic/build-*.json
```

`diagnostic/build-00000000.logd` and `diagnostic/build-00000000.json` are stub
examples. They document the expected file shape, but they are not valid incident
evidence and are not valid payout evidence for bounty submissions. A real run is
named from the current commit, for example `diagnostic/build-1a2b3c4d.logd`
with matching `diagnostic/build-1a2b3c4d.json`.

When the JSON metadata exists, inspect the module list before changing the
system:

```sh
python3 -m json.tool diagnostic/build-$(git rev-parse --short=8 HEAD).json
```

Record the failing module, command output, commit, environment, and whether the
encrypted `.logd` was created. If `build.py` cannot create a `.logd`, keep the
matching JSON because it explains the diagnostic failure.

## Failed Build Diagnostics

Use this when CI, a release candidate, or a local verification run fails before
deployment.

1. Confirm the failing revision:

   ```sh
   git status --short
   git rev-parse --short=8 HEAD
   ```

2. Run the same diagnostic build that pull requests are required to attach:

   ```sh
   python3 build.py
   python3 build.py --module backend,frontend
   python3 build.py --release --module backend
   ```

3. Read the generated metadata and match the failing module to its configured
   command in `build.py`:

   ```sh
   python3 -m json.tool diagnostic/build-$(git rev-parse --short=8 HEAD).json
   ```

   Module commands include `cargo build` for `backend`, `npm run build` for
   `frontend`, `go build -o market .` for `market`, `make` for `frailbox`,
   `cmake --build build` for `frailbox/engine`, `javac -d build
   ComplianceAuditor.java` for `compliance`, `ruby -c market_stream.rb` for
   `v2/services`, `luac -p scanner.lua` for `frailbox/nfc`, `ghc -fno-code`
   under `docs/openapi`, and `luac -p` for the OpenAPI Lua tools.

4. Clean only the affected module before rerunning it:

   ```sh
   python3 build.py --clean --module frontend
   python3 build.py --module frontend
   ```

Escalate the incident if the same module fails on a clean rerun and the JSON
metadata shows a new failure for the current commit.

## Unhealthy Service Checks

Use this when monitoring reports `ServiceDown`, high latency, or a failed
post-deploy health check.

1. Check the repository-defined service endpoints from `docs/OPERATIONS.md`:

   ```sh
   curl -fsS -o /tmp/backend-health.json -w "%{http_code}\n" http://api.example.com:8080/health
   curl -fsS -o /tmp/market-health.json -w "%{http_code}\n" http://api.example.com:8081/health
   curl -fsS -o /tmp/frailbox-health.json -w "%{http_code}\n" http://api.example.com:8082/health
   curl -fsS -o /tmp/frontend-health.html -w "%{http_code}\n" http://api.example.com:3000/
   ```

2. If this is a deployment-related alert, run the matching deployment tool
   health check for the affected service:

   ```sh
   python3 tools/deploy.py --env production --service backend --skip-build --skip-test
   python3 tools/deploy.py --env production --service market --skip-build --skip-test
   python3 tools/deploy.py --env production --service frailbox --skip-build --skip-test
   python3 tools/deploy.py --env production --service frontend --skip-build --skip-test
   ```

3. Compare the failed service to the diagnostic build metadata:

   ```sh
   python3 -m json.tool diagnostic/build-$(git rev-parse --short=8 HEAD).json
   ```

If a service is unhealthy but its module built successfully, treat the incident
as deployment or runtime configuration related. If the module also failed in the
diagnostic metadata, stop roll-forward work and fix or revert the build failure.

## Bad Deployment

Use this when a release reached an environment but caused errors, failed health
checks, or regressions.

1. List the last recorded deployments for the environment:

   ```sh
   python3 tools/deploy.py --env production --list
   python3 tools/deploy.py --env staging --list --service backend
   ```

2. Verify the currently deployed tag against the intended tag in the incident
   notes, then collect a fresh diagnostic bundle from the repository revision:

   ```sh
   git rev-parse --short=8 HEAD
   python3 build.py
   ```

3. Roll back one service at a time. The deploy tool intentionally rejects
   simultaneous all-service rollback:

   ```sh
   python3 tools/deploy.py --env production --service backend --rollback --version v3.1.0
   python3 tools/deploy.py --env production --service frontend --rollback --version v3.1.0
   ```

4. Recheck service health after rollback:

   ```sh
   python3 tools/deploy.py --env production --service backend --skip-build --skip-test
   curl -fsS -o /tmp/backend-health.json -w "%{http_code}\n" http://api.example.com:8080/health
   ```

Do not delete the generated diagnostic bundle during the incident. It ties the
rollback decision to a concrete commit and environment.

## Migration Failure

Use this when schema changes, seed data, or backfills fail.

1. Check migration state before applying more changes:

   ```sh
   python3 tools/db_migration.py --status --env production
   ```

2. Dry-run pending migrations when possible:

   ```sh
   python3 tools/db_migration.py --up --dry-run --env production
   ```

3. If a specific migration must be rolled back, identify the version first and
   then run the targeted rollback:

   ```sh
   python3 tools/db_migration.py --down --version 20240101000000 --env production
   ```

4. For legacy data migrations, use the legacy tool only for cases it explicitly
   supports:

   ```sh
   python3 tools/legacy_migration.py status
   python3 tools/legacy_migration.py dry-run --config config.yaml
   python3 tools/legacy_migration.py rollback --migration-id MIG001
   ```

5. After rollback or repair, capture a new diagnostic bundle and attach the JSON
   metadata to the incident record:

   ```sh
   python3 build.py
   python3 -m json.tool diagnostic/build-$(git rev-parse --short=8 HEAD).json
   ```

Stop if the migration status and diagnostic metadata disagree about the failing
component; that usually means the application revision and database revision are
out of sync.

## OpenAPI Contract Regression

Use this when clients report changed API behavior or contract validation fails.

1. Compare the current checked-in OpenAPI spec to the candidate or deployed
   spec:

   ```sh
   lua tools/openapi_diff.lua --left docs/openapi/v3.yaml --right /tmp/candidate-v3.yaml
   lua tools/openapi_diff.lua --local docs/openapi/v3.yaml --remote https://api.example.com/openapi.yaml
   ```

2. Validate that the OpenAPI tooling still builds:

   ```sh
   python3 build.py --module openapi-haskell,openapi-tools
   ```

3. If the diff shows removed endpoints, changed schemas, or changed security
   fields, treat the incident as a contract regression and pause deployment
   until the API reference and `docs/openapi/v3.yaml` are aligned.

4. Attach the diff output plus the current diagnostic `.logd` and matching JSON
   metadata to the incident record.

## Closeout

Before closing the incident, confirm that the evidence set includes:

- the current commit SHA,
- a real `diagnostic/build-<commit>.logd`,
- matching `diagnostic/build-<commit>.json` metadata when present,
- the exact health, deployment, migration, or OpenAPI commands run,
- the rollback or repair version, and
- a note that `build-00000000` was not used as incident or payout evidence.
