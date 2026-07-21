# Contributing

1. Open an issue describing the compatibility or behavior change.
2. Keep the query callback non-blocking and fail-open.
3. Add focused tests for formatter, validation, filtering, queue, and lifecycle behavior.
4. Run `./scripts/test.sh`, `./scripts/load-test.sh`, and `./scripts/verify-reproducible.sh`.
5. Do not commit internal addresses, domains, query logs, credentials, build caches, or Technitium binaries.

Changes to public configuration, package layout, Technitium interfaces, or security boundaries require compatibility and migration documentation.
