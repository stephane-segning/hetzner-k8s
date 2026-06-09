locals {
  labels = {
    cluster = var.cluster_name
    managed = "terraform"
  }

  k3s_token = var.k3s_token != "" ? var.k3s_token : random_password.k3s_token.result

  normalized_api_server_hostname = trimsuffix(
    trimprefix(
      trimprefix(var.api_server_hostname, "https://"),
      "http://"
    ),
    "/"
  )

  computed_server_args = compact(concat(
    local.normalized_api_server_hostname != "" ? [
      "--tls-san=${local.normalized_api_server_hostname}"
    ] : [],
    var.oidc_issuer_url != "" ? [
      "--kube-apiserver-arg=oidc-issuer-url=${var.oidc_issuer_url}",
      "--kube-apiserver-arg=oidc-client-id=${var.oidc_client_id}",
      "--kube-apiserver-arg=oidc-username-claim=${var.oidc_username_claim}",
      "--kube-apiserver-arg=oidc-groups-claim=${var.oidc_groups_claim}",
      "--kube-apiserver-arg=oidc-username-prefix=${var.oidc_username_prefix}",
      "--kube-apiserver-arg=oidc-groups-prefix=${var.oidc_groups_prefix}"
    ] : [],
    var.extra_server_args != "" ? [var.extra_server_args] : []
  ))

  rendered_server_args = join(" ", local.computed_server_args)

  bootstrap_server_private_ip = cidrhost(module.network.subnet_ip_range, 10)

  etcd_s3_folder_resolved = var.etcd_s3_folder != "" ? var.etcd_s3_folder : "${var.cluster_name}/etcd"

  cloud_init_common = {
    k3s_version                 = var.k3s_version
    k3s_token                   = local.k3s_token
    bootstrap_server_ip         = local.bootstrap_server_private_ip
    etcd_snapshot_schedule_cron = var.etcd_snapshot_schedule_cron
    etcd_snapshot_retention     = var.etcd_snapshot_retention
    etcd_snapshot_compress      = var.etcd_snapshot_compress
    etcd_s3_enabled             = var.etcd_s3_enabled
    etcd_s3_config_secret_name  = var.etcd_s3_config_secret_name
    extra_server_args           = local.rendered_server_args
    extra_agent_args            = var.extra_agent_args
    restore_from_s3             = var.restore_from_s3
    restore_snapshot_name       = var.restore_snapshot_name
    etcd_s3_access_key_id       = var.etcd_s3_access_key_id
    etcd_s3_secret_access_key   = var.etcd_s3_secret_access_key
    etcd_s3_bucket              = var.etcd_s3_bucket
    etcd_s3_endpoint            = var.etcd_s3_endpoint
    etcd_s3_region              = var.etcd_s3_region
    etcd_s3_folder              = local.etcd_s3_folder_resolved
    etcd_s3_bucket_lookup_type  = var.etcd_s3_bucket_lookup_type
    etcd_s3_insecure            = var.etcd_s3_insecure
    etcd_s3_skip_ssl_verify     = var.etcd_s3_skip_ssl_verify
  }

  control_plane_nodes = {
    for index in range(var.control_plane_count) : format("control-plane-%02d", index + 1) => {
      name        = format("%s-cp-%d", var.cluster_name, index + 1)
      role        = "control-plane"
      server_type = var.control_plane_server_type
      private_ip  = cidrhost(module.network.subnet_ip_range, 10 + index)
      user_data = templatefile("${path.module}/../../../bootstrap/cloud-init/node.yaml", merge(local.cloud_init_common, {
        k3s_role           = "control-plane"
        initialize_cluster = index == 0
        node_private_ip    = cidrhost(module.network.subnet_ip_range, 10 + index)
        node_password      = random_password.node_password[format("control-plane-%02d", index + 1)].result
        # Peer control-plane private IPs (excluding self). The bootstrap node's
        # cloud-init probes these before --cluster-init: if a peer already serves
        # the cluster, it JOINS instead of forming a divergent etcd (split-brain
        # guard for a rebuilt cluster-init node).
        control_plane_peer_ips = join(" ", [
          for i in range(var.control_plane_count) :
          cidrhost(module.network.subnet_ip_range, 10 + i) if i != index
        ])
      }))
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
      user_data = templatefile("${path.module}/../../../bootstrap/cloud-init/node.yaml", merge(local.cloud_init_common, {
        k3s_role           = "worker"
        initialize_cluster = false
        node_private_ip    = cidrhost(module.network.subnet_ip_range, 20 + index)
        node_password      = random_password.node_password[format("worker-%02d", index + 1)].result
        # Unused on workers, but templatefile() requires every referenced var.
        control_plane_peer_ips = ""
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

}
