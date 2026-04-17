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

variable "labels" {
  description = "Labels to apply"
  type        = map(string)
  default     = {}
}

variable "http_port" {
  description = "HTTP port"
  type        = number
  default     = 80
}

variable "https_port" {
  description = "HTTPS port"
  type        = number
  default     = 443
}

variable "health_check_port" {
  description = "Health check port"
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "Health check path"
  type        = string
  default     = "/healthz"
}
