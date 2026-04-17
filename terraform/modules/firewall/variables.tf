variable "name" {
  description = "Name prefix for the firewall"
  type        = string
  default     = "k8s"
}

variable "allowed_ssh_ips" {
  description = "IPs allowed to SSH into nodes"
  type        = list(string)
  default     = []
}

variable "allowed_api_ips" {
  description = "IPs allowed to access Kubernetes API"
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels to apply to resources"
  type        = map(string)
  default     = {}
}
