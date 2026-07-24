variable "tenancy_ocid" {}
variable "user_ocid" {}
variable "fingerprint" {}
variable "private_key_path" {}
variable "region" {
  default = "us-ashburn-1"
}
variable "my_ip" {
  
}
variable "compartment_id" {}
variable "ssh_public_key_path" {
  description = "Path to the SSH public key"
  type        = string
  default = "C:/example_folder/example_key.pub"
}
