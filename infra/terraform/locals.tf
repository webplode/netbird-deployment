locals {
  instance_type = "t4g.small"

  nodes = {
    management = {
      role                  = "management"
      hostname              = "${var.name_prefix}-${var.environment}-management"
      subnet_id             = var.subnet_ids.management
      private_ip            = try(var.private_ipv4_addresses.management, null)
      root_volume_size_gib  = var.root_volume_sizes_gib.management
      source_dest_check     = true
      metadata_hop_limit    = 2
      security_group_target = "management"
    }
    peer_1 = {
      role                  = "routing-peer"
      hostname              = "${var.name_prefix}-${var.environment}-peer-1"
      subnet_id             = var.subnet_ids.peer_1
      private_ip            = try(var.private_ipv4_addresses.peer_1, null)
      root_volume_size_gib  = var.root_volume_sizes_gib.peer_1
      source_dest_check     = false
      metadata_hop_limit    = 1
      security_group_target = "peers"
    }
    peer_2 = {
      role                  = "routing-peer"
      hostname              = "${var.name_prefix}-${var.environment}-peer-2"
      subnet_id             = var.subnet_ids.peer_2
      private_ip            = try(var.private_ipv4_addresses.peer_2, null)
      root_volume_size_gib  = var.root_volume_sizes_gib.peer_2
      source_dest_check     = false
      metadata_hop_limit    = 1
      security_group_target = "peers"
    }
  }

  peer_nodes = {
    for key, node in local.nodes : key => node if key != "management"
  }

  eip_cutovers = {
    for key, enabled in var.eip_association_enabled : key => enabled if enabled
  }

  enabled_peer_bootstraps = {
    for key, enabled in var.bootstrap_enabled : key => enabled if enabled && key != "management"
  }

  images = {
    caddy       = "caddy:2.11.4@sha256:844f60b64e4724a5aa8245e019dace0d3f199f7433ce6c57676cb30a920dbad9"
    dashboard   = "netbirdio/dashboard:v2.90.9@sha256:d559f76456df2f06f57108d5271059e085f6d8b510ccdce3c3eac4df15c65121"
    management  = "netbirdio/management:0.76.1@sha256:34cd6872ffaf8430a3e91df7a8a21dc94d1ef89e9df2ab913a509f68ab85b091"
    oauth_proxy = "quay.io/oauth2-proxy/oauth2-proxy:v7.15.3@sha256:10a1165743a192e1940b4708fb9647027185ce11a681a1c5519b442ff7f1f561"
    relay       = "netbirdio/relay:0.76.1@sha256:b08d54bb6bc74bf34cc5c14238923be259422152fb8bad5ff99e6eea264028d6"
    signal      = "netbirdio/signal:0.76.1@sha256:059fe994b561229de9393346111c377bf210137eb5959b47cd6c8463f2694757"
    coturn      = "coturn/coturn:4.7.0@sha256:a00afb5b4890de4df22bbe70379c6b316685dffee297d53cac1271dcb91fab93"
  }

  compose_version        = "5.0.1"
  compose_aarch64_sha256 = "e3b36491a75f92c35ebfbbe6e4741bd2429664edf3971427983d67c0b21e7d1d"

  netbird_client = {
    version                = "0.76.1"
    arm64_rpm_sha256       = "19c42fcd1566d3120bc547f631f4b41ba81f864c76ce5fdec393f3476baa9aa2"
    rpm_signing_key_sha256 = "62a19f1371ef014bd9e47fcd4b4c6d62476b7b6e22d530ad64b57c645fc11f5d"
  }

  caddy_config = templatefile("${path.module}/templates/management/Caddyfile.tftpl", {
    acme_ca    = var.acme_ca
    acme_email = var.acme_email
    domain     = var.domain
  })

  compose_config = templatefile("${path.module}/templates/management/docker-compose.yml.tftpl", {
    caddy_image       = local.images.caddy
    coturn_image      = local.images.coturn
    dashboard_image   = local.images.dashboard
    domain            = var.domain
    management_image  = local.images.management
    oauth_proxy_image = local.images.oauth_proxy
    oidc_issuer_url   = var.oidc_issuer_url
    allowed_group     = var.oauth2_allowed_group
    relay_image       = local.images.relay
    signal_image      = local.images.signal
  })
}
