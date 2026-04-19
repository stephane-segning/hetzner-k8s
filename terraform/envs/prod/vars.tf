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
  default     = "fsn1"
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
  description = "Optional DNS hostname for the Kubernetes API endpoint. Used as a TLS SAN when set."
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
  default     = "latest"
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
