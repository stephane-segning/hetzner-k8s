terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.49"
    }
  }
}

resource "hcloud_network" "main" {
  name     = "${var.name}-network"
  ip_range = var.ip_range
  labels   = var.labels
}

resource "hcloud_network_subnet" "main" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = var.subnet_ip_range
}
