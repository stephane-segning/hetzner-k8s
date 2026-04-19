variable "name" {
  description = "Name prefix for the firewall"
  type        = string
  default     = "k8s"
}

variable "labels" {
  description = "Labels to apply to resources"
  type        = map(string)
  default     = {}
}
