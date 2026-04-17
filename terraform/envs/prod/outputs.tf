output "cluster_name" {
  value = var.cluster_name
}

output "k3s_token" {
  value       = local.k3s_token
  sensitive   = true
  description = "Token for joining k3s cluster"
}

output "node_ips" {
  value = {
    public  = module.servers.ipv4_addresses
    private = module.servers.private_ips
  }
  description = "Public and private IP addresses of nodes"
}

output "control_plane_public_ips" {
  value       = module.servers.control_plane_public_ips
  description = "Public IPs of control-plane nodes"
}

output "control_plane_private_ips" {
  value       = module.servers.control_plane_private_ips
  description = "Private IPs of control-plane nodes"
}

output "worker_public_ips" {
  value       = module.servers.worker_public_ips
  description = "Public IPs of worker nodes"
}

output "worker_private_ips" {
  value       = module.servers.worker_private_ips
  description = "Private IPs of worker nodes"
}

output "first_control_plane_ip" {
  value       = module.servers.first_control_plane_public_ip
  description = "Public IP of the bootstrap control-plane node"
}

output "first_control_plane_private_ip" {
  value       = module.servers.first_control_plane_private_ip
  description = "Private IP of the bootstrap control-plane node"
}

output "server_details" {
  value       = module.servers.server_details
  description = "Details of all servers"
}

output "api_load_balancer_ip" {
  value       = module.api_load_balancer.ipv4_address
  description = "Public IPv4 address of the Kubernetes API load balancer"
}

output "api_load_balancer_ipv6" {
  value       = module.api_load_balancer.ipv6_address
  description = "Public IPv6 address of the Kubernetes API load balancer"
}

output "api_server_endpoint" {
  value       = "https://${module.api_load_balancer.ipv4_address}:6443"
  description = "Stable Kubernetes API endpoint for Argo CD and human operators"
}

output "kubeconfig_command" {
  value       = "ssh root@${module.servers.first_control_plane_public_ip} 'cat /etc/rancher/k3s/k3s.yaml'"
  description = "Command to retrieve kubeconfig"
}

output "kubeconfig_path" {
  value       = "kubeconfig"
  description = "Local path for kubeconfig after retrieval"
}

output "bootstrap_commands" {
  value = {
    wait_cluster   = "make bootstrap"
    get_kubeconfig = "ssh root@${module.servers.first_control_plane_public_ip} 'cat /etc/rancher/k3s/k3s.yaml' > kubeconfig && sed -i '' 's/127.0.0.1/${module.api_load_balancer.ipv4_address}/g' kubeconfig"
  }
  description = "Manual bootstrap commands"
  sensitive   = true
}

output "hcloud_ccm_secret_manifest" {
  value       = local.hcloud_ccm_secret
  sensitive   = true
  description = "Rendered Hetzner CCM secret manifest"
}

output "hcloud_csi_secret_manifest" {
  value       = local.hcloud_csi_secret
  sensitive   = true
  description = "Rendered Hetzner CSI secret manifest"
}

output "network_id" {
  value = module.network.network_id
}

output "network_ip_range" {
  value = module.network.ip_range
}
