**# Health Monitoring Dashboard for Domino Datalab Platforms – Blackbox Exporter vs. Gatus Comparison**

(as of 17 April 2026)

### Executive Summary

XYZ operates a fleet of **18 Domino Datalab platforms** on Kubernetes, each exposing a public `/health` JSON endpoint that reports the status of core components (Nucleus, MongoDB, Redis, Vault, Kubernetes, RabbitMQ, Rolling Status, etc.). In addition, we monitor our LLMaaS platform (LiteLLM deployment). The objective is to provide a single, reliable dashboard that visualises the overall health of all platforms and their sub-components.

We have implemented **both** Blackbox Exporter and Gatus in the `a100133-gatus` namespace for evaluation:

- **Blackbox Exporter**: Configured via Prometheus Operator `Probe` CRDs (one probe per component per platform) with dedicated modules and rich static labels (`client_app_code`, `env`, etc.).
- **Gatus**: Configured via a single ConfigMap using a per-component endpoint pattern (multiple endpoints sharing the same `/health` URL with targeted JSONPath conditions).

**Conclusion:** Gatus is the more appropriate and efficient solution for our XYZ Domino Datalab context.

It delivers a native, production-ready UI with significantly lower operational overhead compared to the probe-per-component approach required by Blackbox Exporter.

We recommend standardising on Gatus for the unified health dashboard while optionally retaining Blackbox metrics export for integration with our central Prometheus stack.

### 1. Blackbox Exporter Implementation (Current State)

We are using the standard Prometheus Operator `Probe` CRD pattern. Each probe targets a specific component (e.g., `domino-mongodb-health-datagrid`, `domino-mongodb-health-pace`) and reuses a module defined in `blackbox.yml`.

Key characteristics of our current Blackbox setup:

- One `Probe` resource per component per platform.
- All probes route through our internal Blackbox Exporter service (`domino-blackbox-exporter.a100133-gatus.svc:9115`).
- Rich labelling for observability (`app_name: domino`, `client_name: datagrid`, `client_app_code: ap26180`, `env: PROD`).
- Interval of 1 minute and scrape timeout of 10s.
- JSON validation performed via CEL expressions inside the reusable modules.

This approach provides excellent label-based querying and alerting in Prometheus but results in a large number of Kubernetes objects (119 Probes across 17 platforms and 7 components each).

Visualisation still requires custom Grafana dashboards.

**Example of one of our current Blackbox Probe CRDs (MongoDB – Datagrid platform):**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: domino-mongodb-health-datagrid
  namespace: a100133-gatus
spec:
  interval: 60s
  jobName: domino_mongodb_health
  module: domino_mongodb_health
  scrapeTimeout: 10s
  prober:
    url: domino-blackbox-exporter.a100133-gatus.svc:9115
  targets:
    staticConfig:
      labels:
        app_name: domino
        client_name: datagrid
        client_app_code: ap26180
        env: PROD
      static:
        - https://dmn-ap26180-prod-1b000272.datalab.cloud.echonet/health
```

### 2. Gatus Implementation (Current State)

Our Gatus deployment uses a single ConfigMap (`gatus-config`) with the following characteristics:

- SQLite storage for historical data (`/data/data.db`).
- Prometheus metrics export enabled (`metrics: true`).
- Logical grouping per platform (e.g., group: "Domino Datagrid ap26180").
- Multiple endpoints per platform, all pointing to the same `/health` URL.
- JSONPath conditions adapted to Domino's health structure (top-level or array-based).

This configuration produces a clean, grouped status page out of the box, with one card per component under each Domino platform group.

The entire setup is contained in one ConfigMap, making it easy to manage via GitOps.

**Example of our current Gatus endpoints (extract from gatus-config ConfigMap):**

```yaml
endpoints:
  - name: Nucleus ap26180
    group: "Domino Datagrid ap26180"
    url: "https://dmn-ap26180-prod-1b000272.datalab.cloud.echonet/health"
    interval: 1m
    conditions:
      - "[STATUS] == 200"
      - "[BODY].status == green"

  - name: MongoDB ap26180
    group: "Domino Datagrid ap26180"
    url: "https://dmn-ap26180-prod-1b000272.datalab.cloud.echonet/health"
    interval: 1m
    conditions:
      - "[STATUS] == 200"
      - "[BODY].elements[0].name == mongodb"
      - "[BODY].elements[0].status == green"

  - name: Kubernetes ap26180
    group: "Domino Datagrid ap26180"
    url: "https://dmn-ap26180-prod-1b000272.datalab.cloud.echonet/health"
    interval: 1m
    conditions:
      - "[STATUS] == 200"
      - "[BODY].elements[1].name == kubernetes"
      - "[BODY].elements[1].status == green"
```

### 3. Detailed Comparison

| Aspect                              | Blackbox Exporter (Our Probe CRDs)                                   | Gatus (Our ConfigMap)                                               | Recommended for XYZ |
|-------------------------------------|----------------------------------------------------------------------|---------------------------------------------------------------------|----------------------|
| **Number of Kubernetes Objects**   | High (1 Probe per component per platform ≈ 100+ objects)            | Low (single ConfigMap)                                              | **Gatus**           |
| **Configuration Maintenance**      | Multiple YAML files + blackbox.yml modules                           | Single YAML list of endpoints                                       | **Gatus**           |
| **Native UI / Dashboard**          | None – requires Grafana                                              | Built-in, modern grouped status page                                | **Gatus**           |
| **Component Granularity**          | Excellent via labels                                                 | Excellent via per-component endpoints                               | Tie                 |
| **JSON Condition Flexibility**     | Superior (full CEL support)                                          | Good (JSONPath with array indexing)                                 | Blackbox            |
| **Ease of Adding a New Platform**  | Create 6–8 new Probe CRDs                                            | Copy-paste or template 6–8 endpoint blocks                         | **Gatus**           |
| **Multi-step Workflows (e.g. Vault → LiteLLM)** | Not supported natively                                          | Native Suites with shared context                                   | **Gatus**           |
| **Alerting**                       | Via Alertmanager                                                     | Built-in, simple per-endpoint configuration                         | **Gatus** (simpler) |
| **Prometheus Integration**         | Native metrics source                                                | Exports `/metrics` (already enabled)                                | Blackbox            |
| **Operational Overhead**           | Higher (many CRDs to manage and update)                              | Lower (one ConfigMap)                                               | **Gatus**           |

### 4. Pros & Cons in Our XYZ Domino Datalab Context

**Blackbox Exporter – Pros**  
- Leverages our existing Prometheus Operator investment.  
- Powerful CEL expressions for complex JSON validation in a single rule.  
- Rich static labels enable advanced querying and alerting.

**Blackbox Exporter – Cons**  
- Configuration proliferation ("one probe per dimension of every platform”).  
- No native dashboard – additional Grafana development required.  
- Higher maintenance burden when scaling to all 18 platforms or modifying components.

**Gatus – Pros**  
- Dramatically simpler and more maintainable configuration model.  
- Immediate, ready-to-use dashboard that matches our mental model (one group per platform with all components visible).  
- Built-in support for multi-step Suites (ideal for LLMaaS + Vault secret handling).  
- Lower resource consumption and GitOps-friendly.

**Gatus – Cons**  
- JSONPath conditions slightly less expressive than CEL (our current array indexing works reliably for Domino's structure).  
- Requires careful templating for large-scale repetition across 18 platforms (easily solvable).

### 5. Recommendation & Example Configurations

We strongly recommend **standardising on Gatus** as the primary solution for monitoring the health of our Domino Datalab platforms and the LLMaaS instances.

Gatus directly addresses the original requirements: a native UI, simpler configuration than Blackbox, and built-in support for sequential calls.

It provides faster time-to-value and significantly lower operational overhead while still allowing us to export metrics to our central Prometheus stack if needed.

**Recommended Gatus improvement – Multi-step Suite for LLMaaS + Vault (example):**

```yaml
suites:
  - name: LLMaaS Health with Vault Token
    group: "LLM as a Service"
    interval: 1m
    endpoints:
      - name: Retrieve Vault Token
        url: "https://vault.internal.xyz/health"   # or appropriate Vault endpoint
        conditions:
          - "[STATUS] == 200"
        # Token would be stored in [CONTEXT] for next step
      - name: Query LiteLLM Health
        url: "https://llmaas.xyz.cloud/health"
        headers:
          Authorization: "Bearer [CONTEXT].vault_token"
        conditions:
          - "[STATUS] == 200"
          - "[BODY].status == healthy"
```

**Immediate Next Steps (proposed):**
1. Enhance the existing Gatus ConfigMap with alerts on critical components (Nucleus, MongoDB, Kubernetes, Vault).
2. Implement the Suite pattern above for the LLMaaS platform.
3. Introduce Helm-based templating or a simple generation script to manage the full configuration for all 18 platforms.
4. (Optional) Keep Blackbox Exporter in a limited capacity only for advanced Prometheus alerting rules that cannot be covered by Gatus metrics.
