terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

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

variable "server_type" {
  description = "Hetzner server type for all nodes"
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
  default     = 0
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

variable "allowed_ssh_ips" {
  description = "IPs allowed to SSH into nodes"
  type        = list(string)
  default     = []
}

variable "allowed_api_ips" {
  description = "IPs allowed to access Kubernetes API (empty = any)"
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
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

locals {
  labels = {
    cluster = var.cluster_name
    managed = "terraform"
  }

  k3s_token = var.k3s_token != "" ? var.k3s_token : random_password.k3s_token.result

  bootstrap_server_private_ip = cidrhost(module.network.subnet_ip_range, 10)

  control_plane_nodes = {
    for index in range(var.control_plane_count) : format("control-plane-%02d", index + 1) => {
      name       = format("%s-cp-%d", var.cluster_name, index + 1)
      role       = "control-plane"
      private_ip = cidrhost(module.network.subnet_ip_range, 10 + index)
      user_data = base64encode(templatefile("${path.module}/../../../bootstrap/cloud-init/node.yaml", {
        k3s_version         = var.k3s_version
        k3s_token           = local.k3s_token
        k3s_role            = "control-plane"
        initialize_cluster  = index == 0
        bootstrap_server_ip = local.bootstrap_server_private_ip
        extra_server_args   = var.extra_server_args
        extra_agent_args    = var.extra_agent_args
      }))
      labels = {
        node_pool = "control-plane"
      }
    }
  }

  worker_nodes = {
    for index in range(var.worker_count) : format("worker-%02d", index + 1) => {
      name       = format("%s-worker-%d", var.cluster_name, index + 1)
      role       = "worker"
      private_ip = cidrhost(module.network.subnet_ip_range, 20 + index)
      user_data = base64encode(templatefile("${path.module}/../../../bootstrap/cloud-init/node.yaml", {
        k3s_version         = var.k3s_version
        k3s_token           = local.k3s_token
        k3s_role            = "worker"
        initialize_cluster  = false
        bootstrap_server_ip = local.bootstrap_server_private_ip
        extra_server_args   = var.extra_server_args
        extra_agent_args    = var.extra_agent_args
      }))
      labels = {
        node_pool = "worker"
      }
    }
  }

  nodes = merge(local.control_plane_nodes, local.worker_nodes)

  expected_node_count = var.control_plane_count + var.worker_count

  hcloud_network_name = tostring(module.network.network_id)

  hcloud_ccm_secret = <<-EOT
apiVersion: v1
kind: Secret
metadata:
  name: hcloud
  namespace: kube-system
stringData:
  token: "${var.hcloud_token}"
  network: "${local.hcloud_network_name}"
EOT

  hcloud_csi_secret = <<-EOT
apiVersion: v1
kind: Secret
metadata:
  name: hcloud-csi
  namespace: kube-system
stringData:
  token: "${var.hcloud_token}"
EOT

  platform_secrets = {
    hcloud_ccm = sensitive(local.hcloud_ccm_secret)
    hcloud_csi = sensitive(local.hcloud_csi_secret)
  }
}

resource "random_password" "k3s_token" {
  length           = 32
  special          = true
  override_special = "_-"
}

module "network" {
  source = "../../modules/network"

  name   = var.cluster_name
  labels = local.labels
}

module "firewall" {
  source = "../../modules/firewall"

  name            = var.cluster_name
  allowed_ssh_ips = var.allowed_ssh_ips
  allowed_api_ips = var.allowed_api_ips
  labels          = local.labels
}

module "servers" {
  source = "../../modules/server"

  server_type    = var.server_type
  location       = var.location
  network_id     = module.network.network_id
  firewall_ids   = module.firewall.firewall_ids
  ssh_keys       = var.ssh_key_ids
  labels         = local.labels
  nodes          = local.nodes
  create_volumes = var.create_data_volumes
  volume_size    = var.data_volume_size_gb
}
