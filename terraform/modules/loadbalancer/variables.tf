variable "name" {
  description = "Name for the load balancer"
  type        = string
  default     = "k8s-lb"
}

variable "type" {
  description = "Load balancer type (lb11, lb21, lb31)"
  type        = string
  default     = "lb11"
}

variable "location" {
  description = "Hetzner location"
  type        = string
  default     = "fsn1"
}

variable "network_id" {
  description = "Network ID for private access"
  type        = number
}

variable "target_server_ids" {
  description = "Server IDs to target"
  type        = list(number)
}

variable "use_private_ip" {
  description = "Use private IPs for load balancer targets"
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels to apply"
  type        = map(string)
  default     = {}
}

variable "service_protocol" {
  description = "Load balancer service protocol"
  type        = string
  default     = "tcp"
}

variable "listen_port" {
  description = "Public listen port"
  type        = number
  default     = 6443
}

variable "destination_port" {
  description = "Target port on backend nodes"
  type        = number
  default     = 6443
}

variable "health_check_port" {
  description = "Health check port"
  type        = number
  default     = 6443
}

variable "health_check_protocol" {
  description = "Health check protocol"
  type        = string
  default     = "tcp"
}

variable "health_check_path" {
  description = "Health check path"
  type        = string
  default     = null
}
