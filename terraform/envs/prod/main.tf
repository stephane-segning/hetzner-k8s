resource "random_password" "k3s_token" {
  length           = 32
  special          = true
  override_special = "_-"
}

# Per-node k3s node password. k3s stores hash(node-password) in a
# kube-system Secret <nodename>.node-password.k3s on first join and rejects
# later joins that don't match. Keeping a stable per-node value in Terraform
# state (rather than the random value k3s generates on disk at first boot)
# means a reboot, a `-replace`, or an etcd restore always presents the same
# password and matches the stored Secret. It is per-node (not derived from
# the shared k3s join token) so a leaked join token does not by itself let
# an attacker compute another node's identity password. See ADR-0012.
# Keyed off the deterministic node keys derived from the counts, NOT off
# local.nodes — local.nodes' user_data references this resource, so keying
# on it would create a dependency cycle.
resource "random_password" "node_password" {
  for_each = toset(concat(
    [for i in range(var.control_plane_count) : format("control-plane-%02d", i + 1)],
    [for i in range(var.worker_count) : format("worker-%02d", i + 1)],
  ))

  length  = 32
  special = false
}

module "network" {
  source = "../../modules/network"

  name   = var.cluster_name
  labels = local.labels
}

module "firewall" {
  source = "../../modules/firewall"

  name   = var.cluster_name
  labels = local.labels
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
  use_private_ip   = true
  service_protocol = "tcp"
  listen_port      = 6443
  destination_port = 6443
  # HTTPS /readyz health check (was TCP-only). A TCP probe only proves the port
  # is open — a crash-looping or divergent (split-brain) apiserver can pass it
  # and keep getting traffic. Probing /readyz over TLS proves the apiserver HTTP
  # layer is actually serving. The k3s apiserver requires auth even for /readyz,
  # so an unauthenticated probe returns 401 when UP (and nothing when down), so
  # 401 is accepted as healthy alongside 2xx.
  # NOTE: validate before apply — confirm a healthy CP returns 401 (not 5xx) to
  # `curl -ksi https://<cp>:6443/readyz` so the LB doesn't eject all backends.
  health_check_protocol     = "http"
  health_check_port         = 6443
  health_check_path         = "/readyz"
  health_check_tls          = true
  health_check_status_codes = ["2??", "401"]
}
