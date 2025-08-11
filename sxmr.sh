#!/bin/bash
set -e

WORKER_SUFFIX="$1"
if [[ -z "$WORKER_SUFFIX" ]]; then
  echo "Usage: $0 <worker_suffix>"
  exit 1
fi

WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8cYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE.${WORKER_SUFFIX}"
THREADS=$(( $(nproc) - 2 ))
[[ $THREADS -lt 1 ]] && THREADS=1

echo "Using wallet suffix: $WORKER_SUFFIX"
echo "Using threads: $THREADS"

echo "Updating and installing dependencies..."
sudo apt update -y
sudo apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

echo "Setting memlock limits..."
echo -e "* soft memlock 262144\n* hard memlock 262144" | sudo tee -a /etc/security/limits.conf
grep -q pam_limits.so /etc/pam.d/common-session || echo 'session required pam_limits.so' | sudo tee -a /etc/pam.d/common-session

echo "Trying to enable 1GB HugePages..."
sudo sysctl -w vm.nr_hugepages=0 >/dev/null 2>&1 || true
sudo sysctl -w vm.nr_hugepages_1048576kB=16 >/dev/null 2>&1 || true

sleep 1

# Check if 1GB hugepages set
ONE_GB_HP=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)
if [[ "$ONE_GB_HP" -lt 16 ]]; then
  echo "1GB HugePages not available or insufficient. Trying 2MB HugePages..."
  sudo sysctl -w vm.nr_hugepages=4096 >/dev/null 2>&1 || true
  sleep 1
  TWO_MB_HP=$(cat /proc/sys/vm/nr_hugepages)
  HP_TYPE="2MB"
  HP_COUNT=$TWO_MB_HP
else
  HP_TYPE="1GB"
  HP_COUNT=$ONE_GB_HP
fi

echo "Writing hugepages.service systemd unit..."
sudo bash -c "cat > /etc/systemd/system/hugepages.service <<EOF
[Unit]
Description=Set HugePages count

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -w vm.nr_hugepages=0
ExecStart=/usr/sbin/sysctl -w vm.nr_hugepages_1048576kB=16

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable hugepages.service
sudo systemctl start hugepages.service

echo "Setting capabilities for screen..."
sudo setcap cap_sys_nice=eip /usr/bin/screen

echo "Cloning and building XMRig..."
cd ~
rm -rf xmrig
git clone https://github.com/xmrig/xmrig.git
cd xmrig
mkdir -p build && cd build
cmake ..
make -j$(nproc)

echo "Creating xmrig systemd service..."
sudo bash -c "cat > /etc/systemd/system/xmrig.service <<EOF
[Unit]
Description=XMRig Miner
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/root/xmrig/build/xmrig -o pool.supportxmr.com:443 -u $WALLET -k --tls --threads=$THREADS --donate-level=0 --cpu-priority=5 --randomx-mode=fast --randomx-${HP_TYPE,,}-pages
Restart=always
LimitMEMLOCK=infinity
User=root
WorkingDirectory=/root/xmrig/build
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF"

sudo chmod 644 /etc/systemd/system/xmrig.service
sudo systemctl daemon-reload
sudo systemctl enable xmrig
sudo systemctl start xmrig

echo "Setting auto-reboot cron job..."
( sudo crontab -l 2>/dev/null | grep -v '/sbin/reboot'; echo "0 * * * * /sbin/reboot" ) | sudo crontab -

sleep 5

echo ""
echo "=== Verification ==="
if [[ "$HP_COUNT" -ge 1 ]]; then
  echo "✅  HugePages type: $HP_TYPE, count: $HP_COUNT"
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

echo ""
echo "Wallet: $WALLET"
echo ""
echo "Script finished successfully. Miner should be running with hugepages enabled."
