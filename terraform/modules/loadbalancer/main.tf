terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.49"
    }
  }
}

resource "hcloud_load_balancer" "main" {
  name               = var.name
  load_balancer_type = var.type
  location           = var.location
  labels             = var.labels
}

resource "hcloud_load_balancer_network" "main" {
  load_balancer_id = hcloud_load_balancer.main.id
  network_id       = var.network_id
}

resource "hcloud_load_balancer_target" "main" {
  count = length(var.target_server_ids)

  load_balancer_id = hcloud_load_balancer.main.id
  type             = "server"
  server_id        = var.target_server_ids[count.index]
  use_private_ip   = var.use_private_ip
}

resource "hcloud_load_balancer_service" "main" {
  load_balancer_id = hcloud_load_balancer.main.id
  protocol         = var.service_protocol
  listen_port      = var.listen_port
  destination_port = var.destination_port

  health_check {
    protocol = var.health_check_protocol
    port     = var.health_check_port
    interval = 10
    timeout  = 5
    retries  = 3
    dynamic "http" {
      for_each = contains(["http", "https"], var.health_check_protocol) ? [1] : []
      content {
        path     = coalesce(var.health_check_path, "/")
        domain   = ""
        response = ""
      }
    }
  }
}
