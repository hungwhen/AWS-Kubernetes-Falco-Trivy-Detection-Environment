#!/bin/bash

# Send all output to:
#  - /var/log/user-data.log
#  - system logs
#  - instance console
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# Fail fast on errors
set -e

# If anything fails, print the line number
trap 'echo "[ERROR] User data failed at line $LINENO"' ERR

echo "[INFO] ===== Starting user-data script ====="
echo "[INFO] Current time: $(date)"
echo "[INFO] Running as user: $(whoami)"

###
# 1) Update system and install base tools
###
echo "[STEP 1] Updating system and installing base tools..."
yum update -y
yum install -y curl wget unzip amazon-cloudwatch-agent
echo "[STEP 1] Done installing base tools."

###
# 2) Install Trivy
###
echo "[STEP 2] Installing Trivy (repo + package)..."

# Import Trivy GPG key (new get.trivy.dev endpoint)
rpm --import https://get.trivy.dev/rpm/public.key \
  || echo "[WARN] Failed to import Trivy GPG key (will still try repo)."

cat << 'TRIVYREPO' > /etc/yum.repos.d/trivy.repo
[trivy]
name=Trivy repository
baseurl=https://get.trivy.dev/rpm/releases/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://get.trivy.dev/rpm/public.key
TRIVYREPO

yum clean all
yum makecache
yum install -y trivy
echo "[STEP 2] Trivy installed."

###
# 3) Install Falco via official RPM repo (no deprecated script)
###
echo "[STEP 3] Installing Falco from falcosecurity RPM repo..."

# 3.1 Trust Falco GPG key
rpm --import https://falco.org/repo/falcosecurity-packages.asc

# 3.2 Configure yum repo
curl -fsSL -o /etc/yum.repos.d/falcosecurity.repo \
  https://falco.org/repo/falcosecurity-rpm.repo

# 3.3 Update metadata
yum makecache -y

# 3.4 (Optional) deps for building kmod/ebpf driver.
# These may fail on some kernels; don't kill the whole script if they do.
if ! yum install -y dkms make clang llvm kernel-devel-$(uname -r); then
  echo "[WARN] One or more Falco build deps (dkms/make/clang/llvm/kernel-devel) failed to install. Continuing with modern eBPF."
fi

# 3.5 Install Falco non-interactively, preferring modern eBPF driver
#   FALCO_FRONTEND=noninteractive -> no dialog
#   FALCO_DRIVER_CHOICE=modern_ebpf -> avoid needing kernel headers
FALCO_FRONTEND=noninteractive \
FALCO_DRIVER_CHOICE=modern_ebpf \
yum install -y falco

echo "[STEP 3] Falco package installed."

###
# 4) Configure Falco to log to /var/log/falco/falco.log
###
echo "[STEP 4] Configuring Falco file logging..."
mkdir -p /var/log/falco

cat << 'FALCOCFG' > /etc/falco/falco.yaml
file_output:
  enabled: true
  keep_alive: false
  filename: /var/log/falco/falco.log

stdout_output:
  enabled: false

json_output: true
FALCOCFG

# Enable + restart Falco service (alias + fallbacks)
systemctl enable falco || echo "[WARN] Could not enable falco.service (may already be enabled)."

systemctl restart falco \
  || systemctl restart falco-modern-bpf.service \
  || systemctl restart falco-bpf.service \
  || systemctl restart falco-kmod.service \
  || echo "[WARN] Falco service restart failed."

echo "[STEP 4] Falco service restart attempted. Status (if available):"
systemctl status falco --no-pager || echo "[WARN] Falco status check failed."

###
# 5) Configure CloudWatch Logs for Falco + Trivy
###
echo "[STEP 5] Writing CloudWatch Logs agent config..."
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc

cat << 'CWCONFIG' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/falco/falco.log",
            "log_group_name": "falco-logs",
            "log_stream_name": "{instance_id}/falco",
            "timestamp_format": "%Y-%m-%d %H:%M:%S"
          },
          {
            "file_path": "/var/log/trivy.log",
            "log_group_name": "trivy-logs",
            "log_stream_name": "{instance_id}/trivy",
            "timestamp_format": "%Y-%m-%d %H:%M:%S"
          }
        ]
      }
    }
  }
}
CWCONFIG

echo "[STEP 5] Starting CloudWatch agent..."
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a start \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

systemctl status amazon-cloudwatch-agent --no-pager || echo "[WARN] CloudWatch agent status check failed."
echo "[STEP 5] CloudWatch Logs agent configured."

###
# 6) Run initial Trivy scan
###
echo "[STEP 6] Running initial Trivy scan (HIGH,CRITICAL) on host filesystem..."
trivy fs / --severity HIGH,CRITICAL --no-progress > /var/log/trivy.log 2>&1 \
  || echo "[WARN] Trivy scan failed (this may be okay for initial boot)."
echo "[STEP 6] Initial Trivy scan complete. Log at /var/log/trivy.log"

echo "[INFO] ===== User-data script finished successfully ====="
