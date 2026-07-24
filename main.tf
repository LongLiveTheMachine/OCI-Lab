# ==============================================================================
# TERRAFORM PROVIDER & DATA SOURCES
# ==============================================================================

terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# Find the latest Oracle Linux 9 ARM image
data "oci_core_images" "latest_arm_image" {
  compartment_id           = var.compartment_id
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Helper to find the Availability Domain name automatically
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

# ==============================================================================
# 1. NETWORK TOPOLOGY (VCN, GATEWAY, ROUTE TABLE, SUBNETS)
# ==============================================================================

# Virtual Cloud Network
resource "oci_core_vcn" "internal" {
  dns_label      = "internal"
  cidr_block     = "10.0.0.0/16"
  compartment_id = var.compartment_id
  display_name   = "sec-scraper-network"
}

# Internet Gateway
resource "oci_core_internet_gateway" "scraper_igw" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.internal.id
  enabled        = true
  display_name   = "scraper-igw"
}

# Default Route Table (Routes Internet traffic to IGW)
resource "oci_core_default_route_table" "scraper_default_rt" {
  manage_default_resource_id = oci_core_vcn.internal.default_route_table_id
  compartment_id             = var.compartment_id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.scraper_igw.id
  }
}

# Subnet 1: DMZ / Application Zone
resource "oci_core_subnet" "dmz_subnet" {
  vcn_id            = oci_core_vcn.internal.id
  cidr_block        = "10.0.10.0/24"
  compartment_id    = var.compartment_id
  security_list_ids = [oci_core_security_list.dmz_sec_list.id]
  route_table_id    = oci_core_default_route_table.scraper_default_rt.id
  display_name      = "dmz-subnet-10.0.10.0_24"
}

# Subnet 2: Private / Management Zone
resource "oci_core_subnet" "mgmt_subnet" {
  vcn_id            = oci_core_vcn.internal.id
  cidr_block        = "10.0.20.0/24"
  compartment_id    = var.compartment_id
  security_list_ids = [oci_core_security_list.mgmt_sec_list.id]
  route_table_id    = oci_core_default_route_table.scraper_default_rt.id
  display_name      = "mgmt-subnet-10.0.20.0_24"
}

# ==============================================================================
# 2. FIREWALLS & NETWORK SECURITY LISTS (ACLs)
# ==============================================================================

# Security Rules for DMZ Subnet
resource "oci_core_security_list" "dmz_sec_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.internal.id
  display_name   = "dmz-security-list"

  # Allow Custom SSH Port (2222) from designated IP
  ingress_security_rules {
    protocol = "6" # TCP
    source   = var.my_ip
    tcp_options {
      min = 2222
      max = 2222
    }
  }

  # Allow Web Traffic (HTTP/HTTPS) from anywhere
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # Allow ICMP (Ping) from Management Subnet for health checks
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "10.0.20.0/24"
  }

  # Allow outbound traffic anywhere
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# Security Rules for Management Subnet
resource "oci_core_security_list" "mgmt_sec_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.internal.id
  display_name   = "mgmt-security-list"

  # Allow Custom SSH Port (2222) from designated IP
  ingress_security_rules {
    protocol = "6"
    source   = var.my_ip
    tcp_options {
      min = 2222
      max = 2222
    }
  }

  # Allow Uptime Kuma Monitoring Dashboard (Port 3001) from designated IP
  ingress_security_rules {
    protocol = "6"
    source   = var.my_ip
    tcp_options {
      min = 3001
      max = 3001
    }
  }

  # Allow outbound traffic anywhere
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# ==============================================================================
# 3. COMPUTE INSTANCES & BOOTSTRAP SCRIPTS
# ==============================================================================

# VM 1: Application & Web Server (DMZ Zone)
resource "oci_core_instance" "app_vm" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  display_name        = "app-server-dmz"
  shape               = "VM.Standard.A1.Flex"

  # Splitting resources: 2 OCPUs / 12GB RAM (Fits in Free Tier)
  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.latest_arm_image.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.dmz_subnet.id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)

    user_data = base64encode(<<-EOF
      #!/bin/bash
      exec > /var/log/user-data.log 2>&1

      echo "Starting App Server hardening & configuration..."

      # 1. System Updates & Core Tools
      dnf update -y
      dnf install -y epel-release dnf-utils
      dnf install -y fail2ban policycoreutils-python-utils dnf-automatic aide audit chrony

      # 2. Enable Security Services
      systemctl enable --now auditd
      systemctl enable --now chronyd
      systemctl enable --now dnf-automatic-install.timer

      # 3. File Integrity Monitoring (AIDE)
      aide --init
      mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

      # 4. SSH Hardening (Port 2222, Disable Root/Passwords)
      cat <<EOT > /etc/ssh/sshd_config.d/99-hardeningserver.conf
      Port 2222
      PermitRootLogin no
      PasswordAuthentication no
      ClientAliveInterval 300
      ClientAliveCountMax 0
      MaxAuthTries 3
      Banner /etc/ssh/banner
      EOT

      echo "AUTHORIZED ACCESS ONLY. ALL ACTIVITIES ARE LOGGED." > /etc/ssh/banner
      semanage port -a -t ssh_port_t -p tcp 2222 || echo "SELinux port configured"

      # 5. OS Firewall (firewalld) Config
      firewall-cmd --permanent --add-port=2222/tcp
      firewall-cmd --permanent --add-service=http
      firewall-cmd --permanent --add-service=https
      firewall-cmd --reload

      systemctl restart sshd

      # 6. Fail2Ban Setup
      cat <<EOT > /etc/fail2ban/jail.local
      [sshd]
      enabled = true
      port = 2222
      backend = systemd
      maxretry = 3
      findtime = 10m
      bantime = 1h
      EOT

      systemctl enable --now fail2ban

      # 7. Kernel Tuning
      cat <<EOT >> /etc/sysctl.conf
      net.ipv4.tcp_syncookies = 1
      net.ipv4.icmp_echo_ignore_broadcasts = 1
      net.ipv4.conf.all.rp_filter = 1
      EOT
      sysctl -p

      # 8. Install Docker Engine
      dnf-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable --now docker

      # 9. Deploy Dockerized App Workload (Nginx Web Application)
      docker run -d \
        --name web-app \
        --restart always \
        -p 80:80 \
        nginxdemos/hello

      echo "App Server setup complete."
    EOF
    )
  }
}

# VM 2: Monitoring & Central Observability Server (MGMT Zone)
resource "oci_core_instance" "monitoring_vm" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  display_name        = "monitoring-server-mgmt"
  shape               = "VM.Standard.A1.Flex"

  # Splitting resources: 2 OCPUs / 12GB RAM (Fits in Free Tier)
  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.latest_arm_image.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.mgmt_subnet.id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)

    user_data = base64encode(<<-EOF
      #!/bin/bash
      exec > /var/log/user-data.log 2>&1

      echo "Starting Monitoring Server hardening & configuration..."

      # 1. System Updates & Security Tools
      dnf update -y
      dnf install -y epel-release dnf-utils
      dnf install -y fail2ban policycoreutils-python-utils dnf-automatic aide audit chrony

      # 2. Enable Core Services
      systemctl enable --now auditd
      systemctl enable --now chronyd
      systemctl enable --now dnf-automatic-install.timer

      # 3. File Integrity Monitoring (AIDE)
      aide --init
      mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

      # 4. SSH Hardening (Port 2222)
      cat <<EOT > /etc/ssh/sshd_config.d/99-hardeningserver.conf
      Port 2222
      PermitRootLogin no
      PasswordAuthentication no
      ClientAliveInterval 300
      ClientAliveCountMax 0
      MaxAuthTries 3
      Banner /etc/ssh/banner
      EOT

      echo "AUTHORIZED ACCESS ONLY. ALL ACTIVITIES ARE LOGGED." > /etc/ssh/banner
      semanage port -a -t ssh_port_t -p tcp 2222 || echo "SELinux port configured"

      # 5. OS Firewall Config
      firewall-cmd --permanent --add-port=2222/tcp
      firewall-cmd --permanent --add-port=3001/tcp
      firewall-cmd --reload

      systemctl restart sshd

      # 6. Fail2Ban Setup
      cat <<EOT > /etc/fail2ban/jail.local
      [sshd]
      enabled = true
      port = 2222
      backend = systemd
      maxretry = 3
      findtime = 10m
      bantime = 1h
      EOT

      systemctl enable --now fail2ban

      # 7. Kernel Hardening
      cat <<EOT >> /etc/sysctl.conf
      net.ipv4.tcp_syncookies = 1
      net.ipv4.icmp_echo_ignore_broadcasts = 1
      net.ipv4.conf.all.rp_filter = 1
      EOT
      sysctl -p

      # 8. Install Docker Engine
      dnf-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable --now docker

      # 9. Deploy Uptime Kuma Monitoring Dashboard Container
      docker run -d \
        --name uptime-kuma \
        --restart always \
        -p 3001:3001 \
        -v kuma-data:/app/data \
        louislam/uptime-kuma:1

      echo "Monitoring Server setup complete."
    EOF
    )
  }
}
