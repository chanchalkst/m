#!/bin/bash
WORKER_ID="$1"
if [ -z "$WORKER_ID" ]; then
    echo "Usage: $0 WORKER_ID"
    exit 1
fi

WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE.$WORKER_ID"
THREADS=$(nproc --ignore=2)

echo "[*] Installing dependencies..."
sudo apt update -y
sudo apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

echo "[*] Configuring memlock..."
echo -e "* soft memlock 262144\n* hard memlock 262144" | sudo tee -a /etc/security/limits.conf
grep -q pam_limits.so /etc/pam.d/common-session || echo 'session required pam_limits.so' | sudo tee -a /etc/pam.d/common-session

echo "[*] Detecting hugepage size..."
if [ -d /sys/kernel/mm/hugepages/hugepages-1048576kB ]; then
    HP_SIZE="1GB"
    HP_PATH="/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages"
    HP_COUNT=16
else
    HP_SIZE="2MB"
    HP_PATH="/proc/sys/vm/nr_hugepages"
    HP_COUNT=4096
fi

echo "[*] Setting $HP_SIZE HugePages..."
echo "$HP_COUNT" | sudo tee $HP_PATH

sudo bash -c "cat > /etc/systemd/system/hugepages.service <<EOL
[Unit]
Description=Set HugePages count
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo $HP_COUNT > $HP_PATH'

[Install]
WantedBy=multi-user.target
EOL"

sudo systemctl daemon-reload
sudo systemctl enable hugepages.service
sudo systemctl start hugepages.service
sudo setcap cap_sys_nice=eip /usr/bin/screen

echo "[*] Installing XMRig..."
cd ~
if [ ! -d xmrig ]; then
    git clone https://github.com/xmrig/xmrig.git
fi
cd xmrig && mkdir -p build && cd build
cmake ..
make -j$(nproc)

sudo bash -c "cat > /etc/systemd/system/xmrig.service <<EOL
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
EOL"

sudo chmod 644 /etc/systemd/system/xmrig.service
sudo systemctl daemon-reload
sudo systemctl enable xmrig
sudo systemctl start xmrig

echo "[*] Adding auto-reboot cron job..."
(sudo crontab -l 2>/dev/null | grep -v '/sbin/reboot'; echo "0 * * * * /sbin/reboot") | sudo crontab -

echo
echo "=== Verification ==="
PASS=true

HP_TOTAL=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
if [ "$HP_TOTAL" -ge 1 ]; then
    echo "✅ HugePages active: $HP_TOTAL ($HP_SIZE)"
else
    echo "❌ HugePages not active"
    PASS=false
fi

if systemctl is-active --quiet hugepages.service; then
    echo "✅ hugepages.service running"
else
    echo "❌ hugepages.service not running"
    PASS=false
fi

if systemctl is-active --quiet xmrig; then
    echo "✅ xmrig miner running"
else
    echo "❌ xmrig miner not running"
    PASS=false
fi

if sudo crontab -l | grep -q '/sbin/reboot'; then
    echo "✅ Auto-reboot cron job found"
else
    echo "❌ Auto-reboot cron job missing"
    PASS=false
fi

if [ "$PASS" = true ]; then
    echo
    echo "🎯 Setup complete for worker $WORKER_ID"
    echo "🛠 HugePages: $HP_SIZE ($HP_TOTAL allocated)"
    echo "🚀 Miner: Running with $THREADS threads"
    echo "🔄 Auto-reboot: Enabled"
    echo "Rebooting in 5 seconds..."
    sleep 5
    sudo reboot
else
    echo
    echo "⚠ Some checks failed. Please review above before reboot."
fi
