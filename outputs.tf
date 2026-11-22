output "version" {
  description = "The CirCI release running."
  value       = var.circi_version
}

output "image" {
  description = "The CirCI image running, by name and tag."
  value       = docker_image.circi.name
}

output "public_url" {
  description = "The dashboard's address."
  value       = local.public_url
}
