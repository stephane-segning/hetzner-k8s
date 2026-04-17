output "network_id" {
  value = hcloud_network.main.id
}

output "subnet_id" {
  value = hcloud_network_subnet.main.id
}

output "ip_range" {
  value = var.ip_range
}

output "subnet_ip_range" {
  value = var.subnet_ip_range
}
