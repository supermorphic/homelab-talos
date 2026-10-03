disable_mlock = true
raw_storage_endpoint = true
audit "file" "homelab" {
  description = "Homelab hashed audit output"
  options {
    file_path = "stdout"
    log_raw = "false"
    hmac_accessor = "true"
  }
}
api_addr = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"
listener "tcp" {
  address = "127.0.0.1:8200"
  cluster_address = "127.0.0.1:8201"
  tls_disable = true
}
storage "raft" {
  path = "/openbao/data"
  node_id = "scratch"
}
seal "static" {
  current_key_id = "SEAL_ID"
  current_key = "file:///scratch-seal/key"
}
