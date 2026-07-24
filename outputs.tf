output "app_server_public_ip" {
  description = "Public IP of the Application Server (DMZ)"
  value       = oci_core_instance.app_vm.public_ip
}

output "app_server_private_ip" {
  description = "Private IP of the Application Server (DMZ)"
  value       = oci_core_instance.app_vm.private_ip
}

output "monitoring_server_public_ip" {
  description = "Public IP of the Monitoring Server (MGMT)"
  value       = oci_core_instance.monitoring_vm.public_ip
}

output "monitoring_server_private_ip" {
  description = "Private IP of the Monitoring Server (MGMT)"
  value       = oci_core_instance.monitoring_vm.private_ip
}

output "ssh_command_app_server" {
  description = "SSH command to access App Server on custom port"
  value       = "ssh -p 2222 opc@${oci_core_instance.app_vm.public_ip}"
}

output "ssh_command_monitoring_server" {
  description = "SSH command to access Monitoring Server on custom port"
  value       = "ssh -p 2222 opc@${oci_core_instance.monitoring_vm.public_ip}"
}

output "uptime_kuma_dashboard_url" {
  description = "URL for Uptime Kuma monitoring dashboard"
  value       = "http://${oci_core_instance.monitoring_vm.public_ip}:3001"
}
output "instance_public_ip" {
  description = "The public IP address of the scraper server"
  value       = oci_core_instance.scraper_vm.public_ip
}
