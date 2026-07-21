# Upstream submissions

These drafts are completed with the final release URL, asset size, checksum, and verified compatibility result after production validation. Publishing them is a separate external write.

## Technitium app-store request

Title: Add UniFi Insights Exporter DNS app

Body:

> UniFi Insights Exporter 0.1.0 is a query logger app tested against Technitium DNS Server 15.4. It converts one DNS query into one dnsmasq-compatible RFC3164 UDP message for UniFi Insights Plus. The callback performs validation and a non-blocking write to a bounded in-memory channel; all network I/O runs in a background worker. The app requires no credentials, opens no listener, and stores no queries.
>
> Repository: RELEASE_REPOSITORY_URL
>
> Release and package: RELEASE_URL
>
> License: GPL-3.0-only
>
> Proposed store metadata is available in `package/app-store-entry.json`.

## UniFi Insights Plus issue 89 follow-up

> A native Technitium DNS query logger app is now available as an alternative to the webhook/n8n bridge. It emits the existing parser-compatible format `<PRI>Mon DD HH:MM:SS HOST dnsmasq[PID]: query[TYPE] DOMAIN from CLIENT_IP`, so no Insights Plus change is required.
>
> Repository: RELEASE_REPOSITORY_URL
>
> Release: RELEASE_URL
>
> The current Insights schema still discards resolver-node identity as a dedicated field, RCODE, RTT, transport, answers, and block status. I would be glad to collaborate if a native Technitium schema is considered later.
