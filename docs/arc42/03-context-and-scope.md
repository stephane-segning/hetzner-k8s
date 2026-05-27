# 3. System Scope and Context

## 3.1 Business context

```mermaid
flowchart LR
    Operator[Cluster Operator]
    GH[GitHub Actions]
    HomeArgo[Home-cluster Argo CD]
    Cluster[(ssegning-hetzner-k3s)]
    Workloads[Workloads<br/>Keycloak / CNPG / Redis / Knative / GH Runners / …]
    Users[End users / HTTPS clients]

    Operator -->|workflow_dispatch| GH
    GH -->|terraform apply / kubectl| Cluster
    HomeArgo -->|GitOps sync of platform + apps| Cluster
    Cluster -->|hosts| Workloads
    Users -->|HTTPS via Traefik LB| Workloads
```

## 3.2 Technical context

```mermaid
flowchart TB
    subgraph External
        TF_State[Hetzner Object Storage<br/>Terraform state]
        S3_Etcd[Hetzner Object Storage<br/>etcd snapshots]
        HCAPI[Hetzner Cloud API]
        GHActions[GitHub Actions runners]
        MinIO[dl.min.io<br/>mc binary]
        OIDC[Keycloak<br/>OIDC issuer]
    end

    subgraph Cluster["Hetzner private network 10.0.0.0/16"]
        API_LB["Terraform-managed LB<br/>k8s.ssegning.com:6443<br/>(TCP, target=private:6443)"]
        CP1["control-plane-01<br/>10.0.0.10"]
        CP2["control-plane-02<br/>10.0.0.11"]
        CP3["control-plane-03<br/>10.0.0.12"]
        W1["worker-01<br/>10.0.0.20"]
        W2["worker-02<br/>10.0.0.21"]
        W3["worker-03<br/>10.0.0.22"]
        Ingress_LB["CCM-managed LB<br/>Traefik Service<br/>:80/:443"]
    end

    GHActions -->|HCLOUD_TOKEN| HCAPI
    GHActions -->|AWS_* creds via S3 backend| TF_State
    GHActions -->|/livez via kubeconfig| API_LB
    HCAPI -->|provisions| CP1
    HCAPI -->|provisions| CP2
    HCAPI -->|provisions| CP3
    HCAPI -->|provisions| W1
    HCAPI -->|provisions| W2
    HCAPI -->|provisions| W3
    HCAPI -->|provisions| API_LB
    HCAPI -->|CCM provisions| Ingress_LB

    CP1 -->|etcd-s3 cron upload| S3_Etcd
    CP2 -->|etcd-s3 cron upload| S3_Etcd
    CP3 -->|etcd-s3 cron upload| S3_Etcd

    CP1 -.->|cloud-init restore: mc download| S3_Etcd
    CP1 -.->|cloud-init restore: mc binary| MinIO

    API_LB -->|TCP forward :6443| CP1
    API_LB -->|TCP forward :6443| CP2
    API_LB -->|TCP forward :6443| CP3

    Ingress_LB -->|TCP forward :80/:443| W1
    Ingress_LB -->|TCP forward :80/:443| W2
    Ingress_LB -->|TCP forward :80/:443| W3

    CP1 ---|etcd raft :2380| CP2
    CP2 ---|etcd raft :2380| CP3
    CP1 ---|etcd raft :2380| CP3

    OIDC -.->|kube-apiserver OIDC| API_LB
```

## 3.3 External interfaces

| Direction | System                          | Protocol      | Purpose                                                    |
|-----------|---------------------------------|---------------|------------------------------------------------------------|
| in        | GH Actions → Hetzner Cloud API  | HTTPS REST    | Terraform provisions servers, LB, network, firewall, volumes |
| in        | GH Actions → cluster API LB     | HTTPS (mTLS)  | `/livez` gate, Platform Up `kubectl apply`                |
| in/out    | Home Argo CD ↔ cluster API LB   | HTTPS (mTLS)  | GitOps reconcile via `argocd-manager` ServiceAccount       |
| out       | cluster CPs → Hetzner Obj Stor  | HTTPS S3      | etcd snapshot upload via k3s etcd-s3 cron                  |
| in        | cp-1 cloud-init → Hetzner Obj S | HTTPS S3      | One-shot snapshot download during restore (via `mc`)       |
| in        | cp-1 cloud-init → dl.min.io     | HTTPS         | One-shot `mc` binary download during restore               |
| out       | kube-apiserver → Keycloak       | HTTPS OIDC    | Human auth                                                 |
| in        | end users → Traefik ingress LB  | HTTPS         | Workload traffic                                           |
