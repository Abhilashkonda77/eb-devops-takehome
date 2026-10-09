# Part 5 — ingress-nginx → Gateway API, ~40 Ingresses, no downtime

**Principle:** run old and new side by side and move traffic one host at a time. Never big-bang.

**Order**
1. **Inventory.** Export all 40 Ingresses and group them by the `nginx.ingress.kubernetes.io/*` annotations they use. Plain host/path rules convert easily; regex paths, rewrites, auth, rate limits and snippets are the real scope.
2. **Install** Gateway API CRDs (pinned version) and one implementation (e.g. Envoy Gateway, NGINX Gateway Fabric) next to ingress-nginx, on its own load balancer IP. Platform owns the `Gateway`; teams own their `HTTPRoute`s.
3. **Convert** with `ingress2gateway` as a draft, then review each route by hand.
4. **Validate before any user sees it:** `curl --resolve` against the new IP, comparing status codes, redirects, headers and TLS with the old path. Start with low-risk hosts.
5. **Cut over per host:** lower DNS TTL in advance, switch the record (weighted if possible), keep the old Ingress serving.
6. **Monitor** each cutover: 5xx rate, p95 latency, TLS errors, and traffic actually arriving on the new controller, compared with the old baseline.
7. **Rollback** = point DNS back at ingress-nginx. That only works because old Ingresses stay in place until every host has run clean for days.
8. **Decommission** ingress-nginx last.

**What I expect to break**
- Annotations with no 1:1 equivalent (regex, `configuration-snippet`, `auth-url`, rate limits).
- Rewrite semantics, default timeouts, body-size limits, client-IP headers.
- TLS secrets in other namespaces (needs `ReferenceGrant`).
- Dashboards and alerts built on ingress-nginx metrics.
