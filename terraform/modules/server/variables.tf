variable "image" {
  description = "OS image to use"
  type        = string
  default     = "ubuntu-24.04"
}

variable "location" {
  description = "Hetzner location"
  type        = string
  default     = "nbg1"
}

variable "network_id" {
  description = "Network ID to attach servers to"
  type        = number
}

variable "firewall_ids" {
  description = "Firewall IDs to attach"
  type        = list(number)
  default     = []
}

variable "ssh_keys" {
  description = "SSH key IDs or names"
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Labels to apply to every server"
  type        = map(string)
  default     = {}
}

variable "nodes" {
  description = "Deterministic node definitions"
  type = map(object({
    name        = string
    role        = string
    server_type = string
    private_ip  = string
    user_data   = string
    labels      = optional(map(string), {})
  }))
}

variable "create_volumes" {
  description = "Whether to create data volumes"
  type        = bool
  default     = false
}

variable "volume_size" {
  description = "Size of data volumes in GB"
  type        = number
  default     = 50
}
