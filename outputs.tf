output "instance_public_ip" {
  description = "The public IP address of the scraper server"
  value       = oci_core_instance.scraper_vm.public_ip
}
