terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.49"
    }
  }
}

resource "hcloud_firewall" "main" {
  name   = "${var.name}-firewall"
  labels = var.labels

  rule {
    direction       = "in"
    protocol        = "tcp"
    port            = "any"
    source_ips      = ["0.0.0.0/0", "::/0"]
    description     = "Allow all outbound"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_firewall" "internal" {
  name   = "${var.name}-internal"
  labels = var.labels

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "any"
    source_ips  = ["10.0.0.0/8"]
    description = "Internal network traffic"
  }

  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "any"
    source_ips  = ["10.0.0.0/8"]
    description = "Internal network UDP"
  }

  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["10.0.0.0/8"]
    description = "Internal ICMP"
  }
}
