#!/bin/bash

# Send all output to:
#  - /var/log/user-data.log
#  - system logs
#  - instance console
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# Fail fast on errors
set -e
trap 'echo "[ERROR] User data failed at line $LINENO"' ERR

echo "[INFO] ===== Starting user-data script ====="
echo "[INFO] Current time: $(date)"
echo "[INFO] Running as user: $(whoami)"

############################################
# 1) Update system and install base tools
############################################
echo "[STEP 1] Updating system and installing base tools..."
yum update -y
# curl-minimal is already present on AL2023, so we do NOT install curl.
yum install -y wget unzip amazon-cloudwatch-agent
echo "[STEP 1] Done installing base tools."

############################################
# 2) Install Trivy
############################################
echo "[STEP 2] Installing Trivy (repo + package)..."

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
yum makecache -y
yum install -y trivy
echo "[STEP 2] Trivy installed."

############################################
# 3) Install Falco via official RPM repo
############################################
echo "[STEP 3] Installing Falco from falcosecurity RPM repo..."

rpm --import https://falco.org/repo/falcosecurity-packages.asc

curl -fsSL -o /etc/yum.repos.d/falcosecurity.repo \
  https://falco.org/repo/falcosecurity-rpm.repo

yum makecache -y

# Optional build deps (not fatal if they fail)
if ! yum install -y dkms make clang llvm kernel-devel-$(uname -r); then
  echo "[WARN] One or more Falco build deps (dkms/make/clang/llvm/kernel-devel) failed to install. Continuing with modern eBPF."
fi

FALCO_FRONTEND=noninteractive \
FALCO_DRIVER_CHOICE=modern_ebpf \
yum install -y falco

echo "[STEP 3] Falco installed."

############################################
# 3a) Ensure Falco log path exists
############################################
echo "[STEP 3a] Ensuring Falco log dir/file..."

FALCO_LOG_DIR="/var/log/falco"
FALCO_LOG_FILE="${FALCO_LOG_DIR}/falco.log"

mkdir -p "${FALCO_LOG_DIR}"
touch "${FALCO_LOG_FILE}"

############################################
# 3b) Configure Falco to write to /var/log/falco/falco.log
#     (use config.d, not falco.yaml directly)
############################################
echo "[STEP 3b] Writing Falco file_output config..."

mkdir -p /etc/falco/config.d

cat << 'EOF' > /etc/falco/config.d/file-output.yaml
file_output:
  enabled: true
  keep_alive: false
  filename: /var/log/falco/falco.log

stdout_output:
  enabled: false

json_output: true
EOF

############################################
# 3c) Allow CloudWatch Agent to read Falco logs
############################################
echo "[STEP 3c] Fixing Falco log permissions for cwagent..."

# If cwagent group exists, restrict access to root + cwagent only
if getent group cwagent >/dev/null 2>&1; then
  chown root:cwagent "${FALCO_LOG_DIR}" "${FALCO_LOG_FILE}"
  chmod 750 "${FALCO_LOG_DIR}"      # drwxr-x---  root:cwagent
  chmod 640 "${FALCO_LOG_FILE}"     # -rw-r-----  root:cwagent
else
  # Fallback: slightly more open but still reasonable
  chmod 755 "${FALCO_LOG_DIR}"
  chmod 644 "${FALCO_LOG_FILE}"
fi

echo "[STEP 3c] Falco log permissions set."

############################################
# 4) Enable + restart Falco service
############################################
echo "[STEP 4] Enabling and restarting Falco service..."

systemctl enable falco-modern-bpf.service \
  || systemctl enable falco \
  || echo "[WARN] Could not enable falco service (may already be enabled)."

systemctl restart falco-modern-bpf.service \
  || systemctl restart falco \
  || systemctl restart falco-bpf.service \
  || systemctl restart falco-kmod.service \
  || echo "[WARN] Falco service restart failed."

systemctl status falco-modern-bpf.service --no-pager \
  || systemctl status falco --no-pager \
  || echo "[WARN] Falco status check failed."

############################################
# 5) Configure CloudWatch Logs for Falco + Trivy (.d JSON)
############################################

echo "[STEP 5] 1) Let CloudWatch Agent generate its default config once..."
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a start -m ec2 || true

echo "[STEP 5] 2) Stop CloudWatch Agent so we can inject Falco/Trivy logs..."
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a stop || true

echo "[STEP 5] 3) Ensure CloudWatch .d config directory exists..."
sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d

echo "[STEP 5] 4) Writing Falco + Trivy CloudWatch Logs config (falco-trivy-logs.json)..."

sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d/falco-trivy-logs.json >/dev/null <<'EOF'
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
EOF

echo "[STEP 5] Listing CloudWatch agent .d config dir after injection..."
sudo ls -l /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d

echo "[STEP 5] 5) Restarting CloudWatch Agent using .d directory config..."

sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a start \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d

systemctl status amazon-cloudwatch-agent --no-pager \
  || echo "[WARN] CloudWatch agent status check failed."

echo "[STEP 5] CloudWatch Logs agent configured for Falco + Trivy."


############################################
# 6) Run initial Trivy scan (HIGH,CRITICAL)
############################################
echo "[STEP 6] Preparing Trivy temp and cache directories..."

TRIVY_TMP_DIR="/var/trivy-tmp"
TRIVY_CACHE_DIR="/var/trivy-cache"

mkdir -p "$TRIVY_TMP_DIR" "$TRIVY_CACHE_DIR"
chmod 777 "$TRIVY_TMP_DIR" "$TRIVY_CACHE_DIR"

if mountpoint -q /tmp; then
  echo "[STEP 6] Attempting to remount /tmp with 1G size (best effort)..."
  mount -o remount,size=1G /tmp 2>/dev/null || echo "[WARN] Could not remount /tmp; continuing with custom TMPDIR."
fi

echo "[STEP 6] Running initial Trivy scan (HIGH,CRITICAL) on host filesystem..."

export TMPDIR="$TRIVY_TMP_DIR"

trivy fs / \
  --severity HIGH,CRITICAL \
  --no-progress \
  --cache-dir "$TRIVY_CACHE_DIR" \
  --exit-code 0 \
  --format table \
  --output /var/log/trivy.log || echo "[WARN] Trivy scan finished with non-zero exit code $?"

echo "[STEP 6] Trivy step finished (see /var/log/trivy.log and CloudWatch Logs)."

############################################
# 7) Sanity checks
############################################
echo "[CHECK] ===== Running post-install sanity checks ====="

# Falco active?
if systemctl is-active --quiet falco-modern-bpf.service; then
  echo "[CHECK] Falco service (falco-modern-bpf) is ACTIVE."
elif systemctl is-active --quiet falco; then
  echo "[CHECK] Falco service (falco) is ACTIVE."
else
  echo "[CHECK][WARN] Falco service is NOT active. See: systemctl status falco-modern-bpf.service"
fi

# Falco health endpoint (if enabled)
if curl -sSf http://localhost:8765/healthz >/dev/null 2>&1; then
  echo "[CHECK] Falco health endpoint responded OK on http://localhost:8765/healthz"
else
  echo "[CHECK][WARN] Falco health endpoint not reachable (may be disabled in config)."
fi

# Falco log non-empty
if [ -s /var/log/falco/falco.log ]; then
  echo "[CHECK] Falco log file exists and is non-empty at /var/log/falco/falco.log"
else
  echo "[CHECK][WARN] Falco log file is empty or missing at /var/log/falco/falco.log"
fi

# Trivy log presence
if [ -s /var/log/trivy.log ]; then
  echo "[CHECK] Trivy log file exists and is non-empty at /var/log/trivy.log"
else
  echo "[CHECK][WARN] Trivy log file is empty or missing at /var/log/trivy.log"
fi

# CloudWatch agent running
if systemctl is-active --quiet amazon-cloudwatch-agent; then
  echo "[CHECK] CloudWatch agent is ACTIVE."
else
  echo "[CHECK][WARN] CloudWatch agent is NOT active. See: systemctl status amazon-cloudwatch-agent"
fi

echo "[CHECK] ===== Sanity checks complete ====="
echo "[INFO] ===== User-data script finished successfully ====="
