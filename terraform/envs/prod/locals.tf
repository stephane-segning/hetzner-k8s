locals {
  labels = {
    cluster = var.cluster_name
    managed = "terraform"
  }

  k3s_token = var.k3s_token != "" ? var.k3s_token : random_password.k3s_token.result

  bootstrap_server_private_ip = cidrhost(module.network.subnet_ip_range, 10)

  control_plane_nodes = {
    for index in range(var.control_plane_count) : format("control-plane-%02d", index + 1) => {
      name        = format("%s-cp-%d", var.cluster_name, index + 1)
      role        = "control-plane"
      server_type = var.control_plane_server_type
      private_ip  = cidrhost(module.network.subnet_ip_range, 10 + index)
      user_data = templatefile("${path.module}/../../../bootstrap/cloud-init/node.yaml", {
        k3s_version         = var.k3s_version
        k3s_token           = local.k3s_token
        k3s_role            = "control-plane"
        initialize_cluster  = index == 0
        bootstrap_server_ip = local.bootstrap_server_private_ip
        extra_server_args   = var.extra_server_args
        extra_agent_args    = var.extra_agent_args
      })
      labels = {
        node_pool = "control-plane"
      }
    }
  }

  worker_nodes = {
    for index in range(var.worker_count) : format("worker-%02d", index + 1) => {
      name        = format("%s-worker-%d", var.cluster_name, index + 1)
      role        = "worker"
      server_type = var.worker_server_type
      private_ip  = cidrhost(module.network.subnet_ip_range, 20 + index)
      user_data = templatefile("${path.module}/../../../bootstrap/cloud-init/node.yaml", {
        k3s_version         = var.k3s_version
        k3s_token           = local.k3s_token
        k3s_role            = "worker"
        initialize_cluster  = false
        bootstrap_server_ip = local.bootstrap_server_private_ip
        extra_server_args   = var.extra_server_args
        extra_agent_args    = var.extra_agent_args
      })
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

}
