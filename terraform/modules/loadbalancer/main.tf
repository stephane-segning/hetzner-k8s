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
  use_private_ip   = true
}

resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.main.id
  protocol         = "http"
  listen_port      = var.http_port
  destination_port = 80

  health_check {
    protocol = "http"
    port     = var.health_check_port
    interval = 10
    timeout  = 5
    retries  = 3
    http {
      path     = var.health_check_path
      domain   = ""
      response = ""
    }
  }
}

resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.main.id
  protocol         = "https"
  listen_port      = var.https_port
  destination_port = 443

  health_check {
    protocol = "https"
    port     = var.health_check_port
    interval = 10
    timeout  = 5
    retries  = 3
    http {
      path     = var.health_check_path
      domain   = ""
      response = ""
    }
  }
}
