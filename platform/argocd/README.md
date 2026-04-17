apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hetzner-k8s
  namespace: argocd
  labels:
    cluster: hetzner-k8s
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_ORG/YOUR_REPO
    targetRevision: HEAD
    path: platform/base
  destination:
    server: https://YOUR_CLUSTER_URL
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
