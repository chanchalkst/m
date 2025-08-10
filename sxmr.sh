#!/bin/bash
set -euo pipefail

BASE_WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE"
WORKER_ID="${1:-A00001}"
WALLET="$BASE_WALLET.$WORKER_ID"

CPU_CORES=$(nproc)
THREADS=$(( CPU_CORES > 1 ? CPU_CORES - 1 : 1 ))

echo "Using wallet: $WALLET"
echo "Mining on $THREADS threads (CPU cores: $CPU_CORES)"

sudo apt update
sudo apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

grep -qxF "* soft memlock 262144" /etc/security/limits.conf || echo -e "* soft memlock 262144\n* hard memlock 262144" | sudo tee -a /etc/security/limits.conf

for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  if ! grep -q pam_limits.so "$f"; then
    echo 'session required pam_limits.so' | sudo tee -a "$f"
  fi
done

grep -qxF "vm.nr_hugepages=128" /etc/sysctl.conf || echo "vm.nr_hugepages=128" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

sudo setcap cap_sys_nice=eip "$(which screen)"

cd /root || { echo "Failed to access /root"; exit 1; }

if [ ! -d xmrig ]; then
  echo "Cloning xmrig repo..."
  git clone https://github.com/xmrig/xmrig.git
fi

cd xmrig || { echo "Failed to enter xmrig directory"; exit 1; }
mkdir -p build
cd build || { echo "Failed to enter build directory"; exit 1; }

echo "Running cmake..."
cmake ..

echo "Running make..."
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

sudo chmod 644 /etc/systemd/system/xmrig.service
sudo systemctl daemon-reload
sudo systemctl enable xmrig
sudo systemctl start xmrig

# Schedule reboot every 2 hours (without duplicates)
(sudo crontab -l 2>/dev/null | grep -v '/sbin/reboot'; echo "0 */2 * * * /sbin/reboot") | sudo crontab -

# Verify reboot cron exists
if ! sudo crontab -l 2>/dev/null | grep -q '/sbin/reboot'; then
  echo "ERROR: Reboot schedule NOT set in crontab!"
  exit 1
fi

# Verify service enabled and active
if ! sudo systemctl is-enabled xmrig &>/dev/null; then
  echo "ERROR: xmrig service is NOT enabled!"
  exit 1
fi

if ! sudo systemctl is-active xmrig &>/dev/null; then
  echo "ERROR: xmrig service is NOT active!"
  exit 1
fi

echo "Setup complete. Miner running with wallet $WALLET."
echo "Reboot scheduled every 2 hours."
