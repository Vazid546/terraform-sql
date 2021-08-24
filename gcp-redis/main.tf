provider "google" {
  credentials = file("credentials.json")

  project = "adept-figure-323906"
  region  = "us-central1"
  zone    = "us-central1-a"
}

module "redis" {
    source = "./redis"
    project_id = "adept-figure-323906"
    enable_apis = true
    activate_apis = ["redis.googleapis.com"]
    activate_api_identities = []
    disable_services_on_destroy = true
    disable_dependent_services = true
    instance_details = [
        {
            name = "redis1"
            authorized_network = "default"
            tier = "STANDARD_HA"
            memory_size_gb = 2
            location_id = "us-central1-a"
            alternative_location_id = null
            redis_configs = {}
            redis_version = null
            display_name = "Redis 1"
            reserved_ip_range = null     
            connect_mode = null
            labels = { "env" = "dev"},
            auth_enabled = false,
            transit_encryption_mode = "SERVER_AUTHENTICATION"
        }
    ]
}