#!/bin/bash
# xmrig_setup.sh
# Setup XMRig miner on Ubuntu with auto start and reboot every 2 hours
# Usage: sudo bash xmrig_setup.sh [WORKER_ID]
# Default WORKER_ID = A00001

set -euo pipefail

BASE_WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE"
WORKER_ID="${1:-A00001}"
WALLET="$BASE_WALLET.$WORKER_ID"

echo "Using wallet: $WALLET"

CPU_CORES=$(nproc)
THREADS=$(( CPU_CORES > 1 ? CPU_CORES - 1 : 1 ))
echo "Mining on $THREADS threads (CPU cores: $CPU_CORES)"

echo "Updating system and installing dependencies..."
sudo apt update
sudo apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

echo "Configuring system limits..."
echo -e "* soft memlock 262144\n* hard memlock 262144" | sudo tee -a /etc/security/limits.conf

for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  if ! grep -q pam_limits.so "$f"; then
    echo 'session required pam_limits.so' | sudo tee -a "$f"
  fi
done

echo "Setting hugepages..."
if ! grep -q '^vm.nr_hugepages=128' /etc/sysctl.conf; then
  echo 'vm.nr_hugepages=128' | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

echo "Setting capabilities for screen..."
sudo setcap cap_sys_nice=eip "$(which screen)"

echo "Preparing XMRig source..."
cd /root
if [ ! -d xmrig ]; then
  git clone https://github.com/xmrig/xmrig.git
fi

cd xmrig
mkdir -p build
cd build

echo "Building XMRig..."
cmake ..
make -j"$CPU_CORES"

echo "Creating systemd service file..."
sudo tee /etc/systemd/system/xmrig.service > /dev/null <<EOF
[Unit]
Description=XMRig Miner Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/root/xmrig/build/xmrig -o pool.supportxmr.com:443 -u $WALLET -k --tls --threads=$THREADS --donate-level=0 --cpu-priority=2 --randomx-mode=fast --randomx-1gb-pages
Restart=always
LimitMEMLOCK=infinity
User=root
WorkingDirectory=/root/xmrig/build
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd daemon and enabling xmrig service..."
sudo chmod 644 /etc/systemd/system/xmrig.service
sudo systemctl daemon-reload
sudo systemctl enable xmrig

if systemctl is-enabled xmrig &>/dev/null; then
  echo "Service 'xmrig' enabled to start on boot."
else
  echo "Error: Service 'xmrig' not enabled on boot."
  exit 1
fi

echo "Starting xmrig service..."
sudo systemctl start xmrig

echo "Scheduling reboot every 2 hours..."
(sudo crontab -l 2>/dev/null; echo "0 */2 * * * /sbin/reboot") | sudo crontab -

if sudo crontab -l | grep -q '/sbin/reboot'; then
  echo "Reboot scheduled every 2 hours."
else
  echo "Error: Failed to schedule reboot."
  exit 1
fi

echo "Setup complete. Miner is running with wallet $WALLET."
