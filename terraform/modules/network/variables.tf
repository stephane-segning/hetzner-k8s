variable "name" {
  description = "Name prefix for the network"
  type        = string
  default     = "k8s"
}

variable "ip_range" {
  description = "CIDR range for the private network"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_ip_range" {
  description = "CIDR range for the subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "labels" {
  description = "Labels to apply to resources"
  type        = map(string)
  default     = {}
}
