# Security

## Trust boundaries

- Technitium supplies untrusted DNS query content to the callback.
- Configuration is administrative input but is still validated strictly.
- UDP crosses the resolver-to-receiver network boundary without acknowledgement.
- Receiver parsing must not be influenced by query-controlled whitespace or control characters.

## Controls

- QNAME, QTYPE, client IP, hostname, app name, and process ID are validated before formatting.
- Newlines, controls, whitespace injection, invalid labels, unsupported numeric types, and messages over 1024 bytes are rejected.
- Only a pre-parsed numerical destination is used.
- The callback is non-blocking, lock-free with respect to network work, and catches all exceptions.
- Queue, shutdown drain, socket recovery, and error logging are bounded.
- No inbound port, secrets, telemetry, external runtime packages, shell, process spawn, HTTP, temporary per-query file, or persistent query store exists.
- Normal logs contain counters and operational state, never query domains or client IPs.

## Reporting

Report vulnerabilities privately through the repository security policy. Do not attach production DNS logs, credentials, internal domains, or internal addressing to public issues.
