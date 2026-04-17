locals {
  sorted_node_keys = sort(keys(var.nodes))
}

output "server_ids" {
  value = {
    for key, server in hcloud_server.main : key => server.id
  }
}

output "server_names" {
  value = {
    for key, server in hcloud_server.main : key => server.name
  }
}

output "ipv4_addresses" {
  value = {
    for key, server in hcloud_server.main : key => server.ipv4_address
  }
}

output "ipv6_addresses" {
  value = {
    for key, server in hcloud_server.main : key => server.ipv6_address
  }
}

output "private_ips" {
  value = {
    for key, node in var.nodes : key => node.private_ip
  }
}

output "control_plane_public_ips" {
  value = [
    for key in local.sorted_node_keys : hcloud_server.main[key].ipv4_address
    if var.nodes[key].role == "control-plane"
  ]
}

output "control_plane_private_ips" {
  value = [
    for key in local.sorted_node_keys : var.nodes[key].private_ip
    if var.nodes[key].role == "control-plane"
  ]
}

output "worker_public_ips" {
  value = [
    for key in local.sorted_node_keys : hcloud_server.main[key].ipv4_address
    if var.nodes[key].role == "worker"
  ]
}

output "worker_private_ips" {
  value = [
    for key in local.sorted_node_keys : var.nodes[key].private_ip
    if var.nodes[key].role == "worker"
  ]
}

output "first_control_plane_public_ip" {
  value = element([
    for key in local.sorted_node_keys : hcloud_server.main[key].ipv4_address
    if var.nodes[key].role == "control-plane"
  ], 0)
}

output "first_control_plane_private_ip" {
  value = element([
    for key in local.sorted_node_keys : var.nodes[key].private_ip
    if var.nodes[key].role == "control-plane"
  ], 0)
}

output "volume_ids" {
  value = {
    for key, volume in hcloud_volume.data : key => volume.id
  }
}

output "server_details" {
  value = {
    for key, server in hcloud_server.main : key => {
      id         = server.id
      name       = server.name
      public_ip  = server.ipv4_address
      private_ip = var.nodes[key].private_ip
      node_role  = var.nodes[key].role
    }
  }
}
