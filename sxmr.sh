#!/bin/bash
set -e

WALLET_BASE="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8cYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE"
WORKER_ID="$1"
if [[ -z "$WORKER_ID" ]]; then
  echo "Usage: $0 <worker_id_suffix>"
  exit 1
fi
WALLET="${WALLET_BASE}.${WORKER_ID}"
THREADS=$(( $(nproc) - 2 ))
[ $THREADS -lt 1 ] && THREADS=1

# Install dependencies
sudo apt update
sudo apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

# Set memlock limits
echo -e "* soft memlock 262144\n* hard memlock 262144" | sudo tee -a /etc/security/limits.conf
grep -q pam_limits.so /etc/pam.d/common-session || echo 'session required pam_limits.so' | sudo tee -a /etc/pam.d/common-session

# Function to setup hugepages service
setup_hugepages() {
  local size_kb=$1
  local pages=$2
  local service_file="/etc/systemd/system/hugepages.service"
  echo "Trying to enable ${size_kb}KB HugePages..."
  if [[ "$size_kb" == "1048576" ]]; then
    # 1GB pages
    echo "vm.nr_hugepages=0" | sudo tee /etc/sysctl.d/99-hugepages.conf > /dev/null
    echo "vm.nr_hugepages_${size_kb}kB=${pages}" | sudo tee -a /etc/sysctl.d/99-hugepages.conf > /dev/null
  else
    # 2MB pages
    echo "vm.nr_hugepages=${pages}" | sudo tee /etc/sysctl.d/99-hugepages.conf > /dev/null
  fi
  sudo sysctl --system

  sudo bash -c "cat > $service_file" <<EOF
[Unit]
Description=Set HugePages count

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -w vm.nr_hugepages=0
ExecStart=/usr/sbin/sysctl -w vm.nr_hugepages_${size_kb}kB=${pages}

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable hugepages.service
  sudo systemctl start hugepages.service
}

# Try 1GB hugepages (16 pages)
setup_hugepages 1048576 16
sleep 3
ONEGB_FREE=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages 2>/dev/null || echo 0)

if [[ "$ONEGB_FREE" -lt 16 ]]; then
  echo "1GB HugePages not available or insufficient. Trying 2MB HugePages..."
  setup_hugepages 2048 4096
  sleep 3
  TWOMB_FREE=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)
  if [[ "$TWOMB_FREE" -lt 4096 ]]; then
    echo "Failed to allocate enough 2MB HugePages. HugePages might not be properly set."
  fi
fi

# Set cap_sys_nice for screen
sudo setcap cap_sys_nice=eip /usr/bin/screen

# Clone and build xmrig
cd ~
[ ! -d xmrig ] && git clone https://github.com/xmrig/xmrig.git
cd xmrig
mkdir -p build
cd build
cmake .. 
make -j$(nproc)

# Setup xmrig systemd service
sudo bash -c "cat > /etc/systemd/system/xmrig.service" <<EOF
[Unit]
Description=XMRig Miner
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/root/xmrig/build/xmrig -o pool.supportxmr.com:443 -u $WALLET -k --tls --threads=$THREADS --donate-level=0 --cpu-priority=5 --randomx-mode=fast --randomx-1gb-pages
Restart=always
LimitMEMLOCK=infinity
User=root
WorkingDirectory=/root/xmrig/build
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 /etc/systemd/system/xmrig.service
sudo systemctl daemon-reload
sudo systemctl enable xmrig
sudo systemctl start xmrig

# Setup cron for auto reboot hourly
(sudo crontab -l 2>/dev/null; echo "0 * * * * /sbin/reboot") | sudo crontab -

# Verification & output
echo
echo "Using wallet suffix: $WORKER_ID"
echo "Using threads: $THREADS"
echo
echo "=== Verification ==="
ONEGB_ALLOCATED=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)
TWOMB_ALLOCATED=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)

if [[ "$ONEGB_ALLOCATED" -ge 16 ]]; then
  echo "✅  1GB HugePages allocated: $ONEGB_ALLOCATED"
elif [[ "$TWOMB_ALLOCATED" -ge 4096 ]]; then
  echo "✅  2MB HugePages allocated: $TWOMB_ALLOCATED"
else
  echo "❌  HugePages not active"
fi

if systemctl is-active --quiet hugepages.service; then
  echo "✅  hugepages.service running"
else
  echo "❌  hugepages.service not running"
fi

if systemctl is-active --quiet xmrig.service; then
  echo "✅  xmrig miner running"
else
  echo "❌  xmrig miner not running"
fi

if sudo crontab -l | grep -q '/sbin/reboot'; then
  echo "✅  Auto-reboot cron job found"
else
  echo "❌  Auto-reboot cron job missing"
fi

echo
echo "Wallet: $WALLET"
echo
echo "Script finished successfully. Miner should be running with hugepages enabled."
