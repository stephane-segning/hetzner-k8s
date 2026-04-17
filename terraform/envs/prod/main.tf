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

  location       = var.location
  network_id     = module.network.network_id
  firewall_ids   = module.firewall.firewall_ids
  ssh_keys       = var.ssh_key_ids
  labels         = local.labels
  nodes          = local.nodes
  create_volumes = var.create_data_volumes
  volume_size    = var.data_volume_size_gb
}

module "api_load_balancer" {
  source = "../../modules/loadbalancer"

  name              = "${var.cluster_name}-api"
  type              = var.api_load_balancer_type
  location          = var.location
  network_id        = module.network.network_id
  target_server_ids = [for key in sort(keys(local.control_plane_nodes)) : module.servers.server_ids[key]]
  labels = merge(local.labels, {
    role = "kubernetes-api"
  })
  use_private_ip        = true
  service_protocol      = "tcp"
  listen_port           = 6443
  destination_port      = 6443
  health_check_protocol = "tcp"
  health_check_port     = 6443
}
