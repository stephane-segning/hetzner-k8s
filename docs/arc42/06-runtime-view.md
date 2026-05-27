# 6. Runtime View

## 6.1 Routine Infra Up (no restore)

```mermaid
sequenceDiagram
    autonumber
    actor Op as Operator
    participant GH as GitHub Actions
    participant TF as Terraform
    participant HC as Hetzner Cloud
    participant CP1 as control-plane-01
    participant CP23 as control-plane-02/03
    participant W as workers

    Op->>GH: workflow_dispatch Infra Up
    GH->>TF: init + fmt + validate + plan + apply
    TF->>HC: create/update network, firewall, servers, LB
    HC->>CP1: boot + cloud-init
    HC->>CP23: boot + cloud-init
    HC->>W: boot + cloud-init
    CP1->>CP1: ensure_private_nic, install k3s, --cluster-init, systemctl start
    CP23->>CP1: poll /healthz on 10.0.0.10:6443
    CP1-->>CP23: healthy
    CP23->>CP1: install k3s --server=... --token=...
    W->>CP1: poll /healthz
    CP1-->>W: healthy
    W->>CP1: install k3s-agent --server=... --token=...
    GH->>CP1: poll /livez via API LB
    CP1-->>GH: HTTP 401 (TLS works, no auth)
    GH-->>Op: green
```

## 6.2 Restore from S3 — first run

```mermaid
sequenceDiagram
    autonumber
    actor Op as Operator
    participant GH as GitHub Actions
    participant TF as Terraform
    participant LB as API LB
    participant CP1 as control-plane-01 (new VM)
    participant CP23 as control-plane-02/03 (new VMs)
    participant W as workers (new VMs)
    participant S3

    Op->>GH: workflow_dispatch Infra Up<br/>restore_from_s3=true<br/>restore_snapshot_name=...
    GH->>GH: Validate restore inputs<br/>(creds, snapshot name)
    GH->>LB: curl /livez
    Note over GH,LB: 000/connection refused = first restore
    GH->>TF: plan + -replace cp-02, cp-03, all workers
    TF->>CP1: destroy + create (user_data drift forces replace)
    TF->>CP23: destroy + create
    TF->>W: destroy + create

    rect rgba(255, 245, 200, 0.5)
    Note over CP1: Restore branch
    CP1->>CP1: ensure_private_nic
    CP1->>S3: mc download etcd-snapshot-...zip
    S3-->>CP1: 18 MB .zip
    CP1->>CP1: unzip → uncompressed file
    CP1->>CP1: k3s server --cluster-reset<br/>--cluster-reset-restore-path=<abs><br/>--node-ip=10.0.0.10 --etcd-s3=false
    Note over CP1: etcd restored: 22 MB, original CA, all your objects
    CP1->>CP1: touch /var/lib/rancher/k3s/.recovery-restored
    CP1->>CP1: systemctl enable + start k3s
    end

    CP23->>LB: poll /healthz on cp-1
    LB-->>CP23: healthy
    CP23->>CP1: join as new etcd members (raft replicates 22 MB)

    W->>LB: poll /healthz
    LB-->>W: healthy
    W->>CP1: k3s-agent join

    GH->>LB: poll /livez
    LB-->>GH: HTTP 401
    GH-->>Op: green (15 min budget honoured)

    Op->>GH: trigger Platform Up
    Op->>GH: trigger Verify Etcd Backups
```

## 6.3 Restore re-run against an already-restored cluster

```mermaid
sequenceDiagram
    autonumber
    actor Op as Operator
    participant GH as GitHub Actions
    participant TF as Terraform
    participant LB as API LB
    participant CP1 as control-plane-01 (existing)
    participant W as workers (new VMs)

    Op->>GH: Infra Up<br/>restore_from_s3=true (re-run)
    GH->>LB: curl /livez
    LB-->>GH: HTTP 401 (cluster reachable)
    Note over GH: cluster_reachable=true<br/>only -replace workers
    GH->>TF: plan + -replace worker-01..03 only
    TF->>W: destroy + create (3 worker VMs)
    Note over CP1: untouched — sentinel skips cluster-reset path anyway,<br/>etcd quorum preserved
    W->>CP1: join via API LB with current CA
    GH->>LB: poll /livez
    LB-->>GH: HTTP 401
    GH-->>Op: green
```

## 6.4 Platform Up

```mermaid
sequenceDiagram
    autonumber
    actor Op as Operator
    participant GH as GitHub Actions
    participant TF as Terraform
    participant K as kubectl/helm via REMOTE_CLUSTER_KUBECONFIG_B64
    participant Cluster

    Op->>GH: workflow_dispatch Platform Up
    GH->>TF: init (for outputs: network_id, secrets)
    GH->>K: ensure_prerequisites (kubectl version, cluster reachable)
    K->>Cluster: probe
    GH->>K: apply namespaces, Cilium (helm), hcloud Secrets,<br/>k3s-etcd-snapshot-s3-config Secret,<br/>Hetzner CCM (helm), Hetzner CSI (helm),<br/>Traefik (helm), cluster-access, NetworkPolicies
    K->>Cluster: helm install / kubectl apply
    GH-->>Op: green + node list summary
```

## 6.5 Day-2 GitOps: home Argo CD reconciles

```mermaid
sequenceDiagram
    autonumber
    participant Git as Git (this repo + apps repo)
    participant Argo as Home Argo CD
    participant API as cluster API LB
    participant Cluster

    Git-->>Argo: poll (or webhook)
    Argo->>API: GET via argocd-manager ServiceAccount token
    Argo->>API: apply Application manifests
    API->>Cluster: reconcile workloads
    Cluster-->>Argo: status (healthy / progressing / degraded)
```
