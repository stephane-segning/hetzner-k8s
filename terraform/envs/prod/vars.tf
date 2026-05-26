variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "hetzner-k8s"
}

variable "control_plane_server_type" {
  description = "Hetzner server type for control-plane nodes"
  type        = string
  default     = "cpx22"
}

variable "worker_server_type" {
  description = "Hetzner server type for worker nodes"
  type        = string
  default     = "cpx42"
}

variable "control_plane_count" {
  description = "Number of control-plane nodes"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Number of dedicated worker nodes"
  type        = number
  default     = 2
}

variable "location" {
  description = "Hetzner location"
  type        = string
  default     = "nbg1"
}

variable "ssh_key_ids" {
  description = "List of SSH key IDs or names to add to servers"
  type        = list(string)
  default     = []
}

variable "api_load_balancer_type" {
  description = "Hetzner load balancer type for the Kubernetes API endpoint"
  type        = string
  default     = "lb11"
}

variable "api_server_hostname" {
  description = "Optional DNS hostname for the Kubernetes API endpoint, without scheme. Used as a TLS SAN when set."
  type        = string
  default     = ""
}

variable "create_data_volumes" {
  description = "Whether to create data volumes for each server"
  type        = bool
  default     = false
}

variable "data_volume_size_gb" {
  description = "Size of data volumes in GB"
  type        = number
  default     = 50
}

variable "k3s_version" {
  description = "k3s version to install"
  type        = string
  default     = "v1.35.3+k3s1"
}

variable "k3s_token" {
  description = "Token for k3s cluster join (auto-generated if not set)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "extra_server_args" {
  description = "Extra arguments for k3s server"
  type        = string
  default     = ""
}

variable "extra_agent_args" {
  description = "Extra arguments for k3s agents"
  type        = string
  default     = ""
}

variable "etcd_snapshot_schedule_cron" {
  description = "Cron schedule for automatic k3s etcd snapshots on control-plane nodes"
  type        = string
  default     = "0 */6 * * *"
}

variable "etcd_snapshot_retention" {
  description = "Number of automatic k3s etcd snapshots to retain locally on each control-plane node"
  type        = number
  default     = 14
}

variable "etcd_snapshot_compress" {
  description = "Whether to compress automatic k3s etcd snapshots"
  type        = bool
  default     = true
}

variable "etcd_s3_enabled" {
  description = "Whether control-plane nodes should be configured to replicate etcd snapshots to S3 via a kube-system Secret"
  type        = bool
  default     = true
}

variable "etcd_s3_config_secret_name" {
  description = "Name of the kube-system Secret that stores k3s etcd snapshot S3 settings"
  type        = string
  default     = "k3s-etcd-snapshot-s3-config"
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL for Kubernetes API authentication"
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "OIDC client ID for Kubernetes API authentication"
  type        = string
  default     = "kubernetes"
}

variable "oidc_username_claim" {
  description = "OIDC username claim"
  type        = string
  default     = "preferred_username"
}

variable "oidc_groups_claim" {
  description = "OIDC groups claim"
  type        = string
  default     = "groups"
}

variable "oidc_username_prefix" {
  description = "OIDC username prefix"
  type        = string
  default     = "-"
}

variable "oidc_groups_prefix" {
  description = "OIDC groups prefix"
  type        = string
  default     = ""
}

variable "restore_from_s3" {
  description = "If true, the bootstrap control-plane restores etcd from an S3 snapshot instead of running --cluster-init. One-shot recovery flag; flip back to false after the cluster is healthy."
  type        = bool
  default     = false
}

variable "restore_snapshot_name" {
  description = "Filename of the S3 etcd snapshot to restore (e.g. etcd-snapshot-<cluster>-<cp>-<unix>.zip). Required when restore_from_s3 is true."
  type        = string
  default     = ""
}

variable "etcd_s3_access_key_id" {
  description = "S3 access key for the etcd snapshot bucket. Only required when restore_from_s3 is true, because the in-cluster Secret is not yet available during restore."
  type        = string
  sensitive   = true
  default     = ""
}

variable "etcd_s3_secret_access_key" {
  description = "S3 secret key for the etcd snapshot bucket. Only required when restore_from_s3 is true."
  type        = string
  sensitive   = true
  default     = ""
}

variable "etcd_s3_bucket" {
  description = "S3 bucket holding etcd snapshots. Only required when restore_from_s3 is true."
  type        = string
  default     = ""
}

variable "etcd_s3_endpoint" {
  description = "S3 endpoint for the etcd snapshot bucket (e.g. fsn1.your-objectstorage.com). Only required when restore_from_s3 is true."
  type        = string
  default     = ""
}

variable "etcd_s3_region" {
  description = "S3 region for the etcd snapshot bucket."
  type        = string
  default     = "eu-central"
}

variable "etcd_s3_folder" {
  description = "S3 folder/prefix for etcd snapshots. Defaults to <cluster_name>/etcd when empty, matching the Platform Up secret."
  type        = string
  default     = ""
}

variable "etcd_s3_bucket_lookup_type" {
  description = "S3 bucket lookup type used during restore: path or dns."
  type        = string
  default     = "path"
}

variable "etcd_s3_insecure" {
  description = "Allow plaintext HTTP to the S3 endpoint during restore. Stays false for Hetzner Object Storage."
  type        = bool
  default     = false
}

variable "etcd_s3_skip_ssl_verify" {
  description = "Skip TLS verification against the S3 endpoint during restore. Stays false for Hetzner Object Storage."
  type        = bool
  default     = false
}

