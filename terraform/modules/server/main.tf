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
  server_type = var.server_type
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
}

resource "hcloud_volume" "data" {
  for_each = var.create_volumes ? var.nodes : {}

  name      = "${each.value.name}-data"
  size      = var.volume_size
  server_id = hcloud_server.main[each.key].id
  location  = var.location
  labels = merge(var.labels, each.value.labels, {
    node_role = each.value.role
  })
}
