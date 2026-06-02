terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.49"
    }
  }
}

resource "hcloud_server" "main" {
  for_each = var.nodes

  name        = each.value.name
  server_type = each.value.server_type
  image       = var.image
  location    = var.location
  ssh_keys    = var.ssh_keys
  user_data   = each.value.user_data
  labels = merge(var.labels, each.value.labels, {
    node_role = each.value.role
  })

  firewall_ids = var.firewall_ids

  network {
    network_id = var.network_id
    ip         = each.value.private_ip
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # user_data is ForceNew on hcloud_server: any cloud-init edit would
  # otherwise make a routine Infra Up plan to replace EVERY server at once,
  # which the Infra Up workflow's control-plane-replacement guard then
  # blocks (and replacing all control planes simultaneously would break
  # etcd quorum anyway). cloud-init only runs at first boot, so an in-place
  # user_data change never reaches an already-provisioned node regardless.
  # We therefore ignore user_data drift here and roll cloud-init changes out
  # deliberately via `terraform apply -replace=...` of specific nodes (which
  # bypasses ignore_changes and recreates with the current rendered
  # user_data). The Infra Up restore flow does exactly that, including the
  # bootstrap control plane. See ADR-0013.
  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "hcloud_volume" "data" {
  for_each = var.create_volumes ? {
    for key, node in var.nodes : key => node
    if node.role == "worker"
  } : {}

  name      = "${each.value.name}-data"
  size      = var.volume_size
  server_id = hcloud_server.main[each.key].id
  location  = var.location
  labels = merge(var.labels, each.value.labels, {
    node_role = each.value.role
  })
}
