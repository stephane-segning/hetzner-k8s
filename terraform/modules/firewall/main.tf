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

  dynamic "rule" {
    for_each = var.allowed_ssh_ips
    content {
      direction   = "in"
      protocol    = "tcp"
      port        = "22"
      source_ips  = [rule.value]
      description = "SSH access from ${rule.value}"
    }
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = var.allowed_api_ips
    description = "Kubernetes API server"
  }

  rule {
    direction       = "in"
    protocol        = "tcp"
    port            = "any"
    source_ips      = ["0.0.0.0/0", "::/0"]
    description     = "Allow all outbound"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTP ingress"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTPS ingress"
  }

  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP for diagnostics"
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
