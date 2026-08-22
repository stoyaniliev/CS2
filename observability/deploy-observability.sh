#!/bin/bash
# =============================================================================
# Deploy the Innovatech observability stack (REQ-NCA-P2-05, P2-08, P2-09)
#
# Run on the k3s server node. Self-contained: writes its own values files so
# only this one file needs transferring.
#
# Stack:
#   Prometheus     metrics, and the alert rules that generate SOAR events
#   Alertmanager   routes firing alerts to the SOAR ingest API  <- P2-09
#   Loki           logs, with chunks in S3 rather than on local disk
#   Alloy          log collection from pods and from the host
#   Grafana        dashboards, including SOAR operations         <- P2-08
#   cloudwatch-exporter  pulls Lambda and SOAR metrics into Prometheus
#
# The Alertmanager webhook is the join between monitoring and response: an
# alert that fires here becomes an event in the SOAR pipeline, which is what
# makes the observability tool part of the SOAR system rather than adjacent
# to it.
# =============================================================================

set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

SOAR_INGEST_URL="${SOAR_INGEST_URL:-https://lb535ebwpi.execute-api.eu-central-1.amazonaws.com/prod/events}"
S3_BUCKET="${S3_BUCKET:-innovatech-observability-9e024ca1}"
REGION="${REGION:-eu-central-1}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-InnovatechDemo2026}"

echo "=== Configuration ==="
echo "  ingest : $SOAR_INGEST_URL"
echo "  bucket : $S3_BUCKET"
echo "  region : $REGION"

WORK=/opt/innovatech-observability
sudo mkdir -p "$WORK" && sudo chown "$(id -u):$(id -g)" "$WORK"
cd "$WORK"

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# ---------------------------------------------------------------------------
# Prometheus + Alertmanager + Grafana
# ---------------------------------------------------------------------------
cat > kube-prometheus-values.yaml <<YAML
fullnameOverride: monitoring

prometheus:
  prometheusSpec:
    retention: 6h            # short on local disk; long-term history lives in S3
    scrapeInterval: 15s
    evaluationInterval: 15s
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { memory: 2Gi }
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources: { requests: { storage: 10Gi } }
    # Lets us add ServiceMonitors without them needing a matching helm label
    serviceMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    additionalScrapeConfigs:
      - job_name: onprem-nodes
        static_configs:
          - targets: []      # populated once the on-premises hosts are joined
            labels: { environment: onpremises }
      - job_name: demo-workstation
        static_configs:
          - targets: ['10.1.11.193:9100']
            labels:
              environment: cloud
              role: demo-target
              instance_id: i-049e95348a865e18d
  service:
    type: NodePort
    nodePort: 30090

alertmanager:
  config:
    global:
      resolve_timeout: 5m
    route:
      receiver: soar-ingest
      group_by: ['alertname', 'instance']
      group_wait: 10s
      group_interval: 30s
      repeat_interval: 1h
      routes:
        - receiver: soar-ingest
          matchers: [ 'severity =~ "critical|high|warning"' ]
          continue: false
    receivers:
      - name: soar-ingest
        webhook_configs:
          # REQ-NCA-P2-09: monitoring feeds the SOAR pipeline directly.
          - url: '${SOAR_INGEST_URL}'
            send_resolved: false
            max_alerts: 0
  service:
    type: NodePort
    nodePort: 30093

grafana:
  adminPassword: '${GRAFANA_PASSWORD}'
  service:
    type: NodePort
    nodePort: 30030
  grafana.ini:
    server:
      root_url: "%(protocol)s://%(domain)s:30030/"
    users:
      default_theme: dark
  additionalDataSources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki-gateway.monitoring.svc.cluster.local
      jsonData: { maxLines: 1000 }
    - name: CloudWatch
      type: cloudwatch
      jsonData:
        authType: default          # uses the node's instance profile
        defaultRegion: ${REGION}
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      searchNamespace: ALL

nodeExporter: { enabled: true }
kubeStateMetrics: { enabled: true }

# Control-plane component scraping that k3s does not expose separately
kubeControllerManager: { enabled: false }
kubeScheduler: { enabled: false }
kubeProxy: { enabled: false }
kubeEtcd: { enabled: false }
YAML

echo "=== Installing kube-prometheus-stack ==="
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --values kube-prometheus-values.yaml --wait --timeout 12m

# ---------------------------------------------------------------------------
# Loki, backed by S3
#
# This is where "the monitoring application stores its data in a more robust
# and scalable cloud database" is actually satisfied: log chunks and the index
# live in S3, reached over the gateway VPC endpoint, so retention is bounded by
# an S3 lifecycle rule rather than by local disk.
# ---------------------------------------------------------------------------
cat > loki-values.yaml <<YAML
deploymentMode: SingleBinary

loki:
  auth_enabled: false
  commonConfig: { replication_factor: 1 }
  schemaConfig:
    configs:
      - from: 2024-04-01
        store: tsdb
        object_store: s3
        schema: v13
        index: { prefix: index_, period: 24h }
  storage:
    type: s3
    bucketNames:
      chunks: ${S3_BUCKET}
      ruler: ${S3_BUCKET}
    s3:
      region: ${REGION}
      s3ForcePathStyle: false
      insecure: false
      # No credentials: the node's IAM instance profile is used.
  limits_config:
    retention_period: 720h
    ingestion_rate_mb: 8
  compactor:
    working_directory: /var/loki/compactor
    delete_request_store: s3
    retention_enabled: true

singleBinary:
  replicas: 1
  persistence: { enabled: true, size: 10Gi }
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { memory: 1Gi }

# Microservice components off: single-binary mode covers this scale
backend:   { replicas: 0 }
read:      { replicas: 0 }
write:     { replicas: 0 }
chunksCache:  { enabled: false }
resultsCache: { enabled: false }
lokiCanary:   { enabled: false }
test:         { enabled: false }
gateway:      { enabled: true }
YAML

echo "=== Installing Loki ==="
helm upgrade --install loki grafana/loki \
  --namespace monitoring --values loki-values.yaml --wait --timeout 10m

# ---------------------------------------------------------------------------
# Alloy: collects pod logs and host syslog, ships to Loki
# ---------------------------------------------------------------------------
cat > alloy-values.yaml <<'YAML'
alloy:
  configMap:
    content: |
      discovery.kubernetes "pods" {
        role = "pod"
      }

      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
      }

      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pods.output
        forward_to = [loki.write.default.receiver]
      }

      // Host syslog, so the cluster node's own auth events are searchable
      // alongside the on-premises ones.
      local.file_match "syslog" {
        path_targets = [{"__path__" = "/var/log/{syslog,auth.log}", "job" = "node-syslog"}]
      }

      loki.source.file "syslog" {
        targets    = local.file_match.syslog.targets
        forward_to = [loki.write.default.receiver]
      }

      loki.write "default" {
        endpoint {
          url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
        }
      }
  mounts:
    varlog: true
YAML

echo "=== Installing Alloy ==="
helm upgrade --install alloy grafana/alloy \
  --namespace monitoring --values alloy-values.yaml --wait --timeout 5m

# ---------------------------------------------------------------------------
# cloudwatch-exporter: brings the SOAR Lambda metrics into Prometheus.
#
# Without this the SOAR system's own health would only be visible in the AWS
# console, and REQ-NCA-P2-08 asks for it on the central dashboard.
# ---------------------------------------------------------------------------
cat > cloudwatch-exporter-values.yaml <<YAML
aws:
  region: ${REGION}
  role: ""          # instance profile
  aws_access_key_id: ""
  aws_secret_access_key: ""

serviceMonitor:
  enabled: true
  namespace: monitoring
  labels: { release: monitoring }

config: |-
  region: ${REGION}
  period_seconds: 60
  metrics:
    - aws_namespace: Innovatech/SOAR
      aws_metric_name: EventsIngested
      aws_dimensions: [Source, Severity]
      aws_statistics: [Sum]
    - aws_namespace: Innovatech/SOAR
      aws_metric_name: PlaybookMatched
      aws_dimensions: [PlaybookId]
      aws_statistics: [Sum]
    - aws_namespace: Innovatech/SOAR
      aws_metric_name: ActionsDispatched
      aws_dimensions: [ActionType, PlaybookId]
      aws_statistics: [Sum]
    - aws_namespace: Innovatech/SOAR
      aws_metric_name: ActionsExecuted
      aws_dimensions: [ActionType]
      aws_statistics: [Sum]
    - aws_namespace: Innovatech/SOAR
      aws_metric_name: ActionsFailed
      aws_dimensions: [ActionType]
      aws_statistics: [Sum]
    - aws_namespace: Innovatech/SOAR
      aws_metric_name: ActionsSkipped
      aws_dimensions: [ActionType, Reason]
      aws_statistics: [Sum]
    - aws_namespace: Innovatech/SOAR
      aws_metric_name: EventsUnmatched
      aws_dimensions: [EventType]
      aws_statistics: [Sum]
    - aws_namespace: AWS/Lambda
      aws_metric_name: Invocations
      aws_dimensions: [FunctionName]
      aws_statistics: [Sum]
    - aws_namespace: AWS/Lambda
      aws_metric_name: Errors
      aws_dimensions: [FunctionName]
      aws_statistics: [Sum]
    - aws_namespace: AWS/Lambda
      aws_metric_name: Duration
      aws_dimensions: [FunctionName]
      aws_statistics: [Average, Maximum]
    - aws_namespace: AWS/SQS
      aws_metric_name: ApproximateNumberOfMessagesVisible
      aws_dimensions: [QueueName]
      aws_statistics: [Maximum]
YAML

echo "=== Installing cloudwatch-exporter ==="
helm upgrade --install cloudwatch-exporter prometheus-community/prometheus-cloudwatch-exporter \
  --namespace monitoring --values cloudwatch-exporter-values.yaml --wait --timeout 5m

# ---------------------------------------------------------------------------
# Alert rules that generate SOAR events.
#
# The soar_event_type label is what the collector maps onto a playbook, so the
# alert name and the playbook match criteria stay decoupled.
# ---------------------------------------------------------------------------
cat > soar-alert-rules.yaml <<'YAML'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: soar-rules
  namespace: monitoring
  labels: { release: monitoring }
spec:
  groups:
    - name: innovatech.availability
      rules:
        - alert: TargetDown
          expr: up == 0
          for: 1m
          labels:
            severity: high
            soar_event_type: ServiceDown
          annotations:
            summary: "{{ $labels.job }} target {{ $labels.instance }} is unreachable"
            description: "Prometheus has failed to scrape {{ $labels.instance }} for over a minute."

        - alert: HostHighCpu
          expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
          for: 3m
          labels:
            severity: warning
            soar_event_type: HostHighCpu
          annotations:
            summary: "CPU above 85% on {{ $labels.instance }}"

        - alert: HostLowDisk
          expr: (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes) * 100 < 15
          for: 5m
          labels:
            severity: warning
            soar_event_type: HostLowDisk
          annotations:
            summary: "Less than 15% disk free on {{ $labels.instance }}"

    - name: innovatech.soar-health
      rules:
        # The SOAR system monitoring itself (REQ-NCA-P2-08).
        - alert: SoarActionsFailing
          expr: sum(rate(aws_innovatech_soar_actions_failed_sum[5m])) > 0
          for: 2m
          labels:
            severity: critical
            soar_event_type: SoarDegraded
          annotations:
            summary: "SOAR response actions are failing"
            description: "One or more automated responses could not be executed. Security events may be going unhandled."

        - alert: SoarDeadLetterQueueNotEmpty
          expr: aws_sqs_approximate_number_of_messages_visible_maximum{queue_name=~".*dlq"} > 0
          for: 5m
          labels:
            severity: high
            soar_event_type: SoarDegraded
          annotations:
            summary: "Messages parked in a SOAR dead-letter queue"
YAML

kubectl apply -f soar-alert-rules.yaml

echo
echo "=== Deployed ==="
kubectl get pods -n monitoring
NODE_IP=$(hostname -I | awk '{print $1}')
echo
echo "Grafana       http://${NODE_IP}:30030   (admin / ${GRAFANA_PASSWORD})"
echo "Prometheus    http://${NODE_IP}:30090"
echo "Alertmanager  http://${NODE_IP}:30093"
echo
echo "Reachable from the bastion and, once routes are approved, from on-premises."
