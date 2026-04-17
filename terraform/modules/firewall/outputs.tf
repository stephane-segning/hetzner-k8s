output "firewall_id" {
  value = hcloud_firewall.main.id
}

output "internal_firewall_id" {
  value = hcloud_firewall.internal.id
}

output "firewall_ids" {
  value = [hcloud_firewall.main.id, hcloud_firewall.internal.id]
}
