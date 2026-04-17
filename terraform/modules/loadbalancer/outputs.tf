output "load_balancer_id" {
  value = hcloud_load_balancer.main.id
}

output "load_balancer_name" {
  value = hcloud_load_balancer.main.name
}

output "ipv4_address" {
  value = hcloud_load_balancer.main.ipv4
}

output "ipv6_address" {
  value = hcloud_load_balancer.main.ipv6
}

output "hostname" {
  value = "${hcloud_load_balancer.main.ipv4}.your-talos.com"
}
