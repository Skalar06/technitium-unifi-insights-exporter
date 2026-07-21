# Installation

## Preconditions

- successful clean build, tests, package validation, and checksum verification;
- backup of Technitium configuration, app packages/configuration, cluster state, Compose definitions, and image digests;
- tested rollback records for any legacy exporter, workflow, and relay;
- explicit approval for the concrete test or production change.

## Disabled cluster installation

Install `dist/TechnitiumUniFiInsightsExporter-0.1.0.zip` on the Technitium primary under the app name `UniFi Insights Exporter`. Retain the package configuration with `enabled=false`.

On every node verify:

- app name and version;
- DLL load without missing dependencies;
- identical configuration;
- no export counters or receiver traffic;
- DNS resolution and cluster health;
- no container restart.

If the app does not replicate, record the observed cluster behavior before considering per-node installation. Do not assume node-local configuration: Technitium cluster app configuration is shared.

## Canary

Enable one resolver domain in `nodePolicy.serverDomains`. Keep any legacy path active only long enough to prove the new RFC3164 hostname in bounded receiver data. Run direct A, AAAA, and HTTPS test queries and verify exactly one app-originated datagram per query.

Do not embed API tokens in scripts or command arguments. Production installation and configuration changes must use the approved Technitium Admin API/Gateway path with redacted output.
