#!/bin/bash
# =========================================
# XMRig Auto Installer + Auto Reboot Hourly
# =========================================

# --- User Wallet ---
WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE"
POOL="pool.supportxmr.com:443"

# --- Get worker name from user ---
read -p "Enter Worker Name: " WORKER
THREADS=$(nproc --ignore=1)

# --- Install dependencies ---
sudo apt update
sudo apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

# --- Memory & hugepages config ---
echo -e "* soft memlock 262144\n* hard memlock 262144" | sudo tee -a /etc/security/limits.conf >/dev/null
grep -q pam_limits.so /etc/pam.d/common-session || echo 'session required pam_limits.so' | sudo tee -a /etc/pam.d/common-session >/dev/null
echo 'vm.nr_hugepages=128' | sudo tee -a /etc/sysctl.conf >/dev/null
sudo sysctl -w vm.nr_hugepages=128
sudo setcap cap_sys_nice=eip /usr/bin/screen

# --- Download & build xmrig ---
cd ~
if [ ! -d "xmrig" ]; then
    git clone https://github.com/xmrig/xmrig.git
fi
cd xmrig && mkdir -p build && cd build
cmake .. && make -j$(nproc)

# --- Create systemd service ---
sudo tee /etc/systemd/system/xmrig.service >/dev/null <<EOF
[Unit]
Description=XMRig Miner
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/root/xmrig/build/xmrig -o $POOL -u $WALLET.$WORKER -k --tls --threads=$THREADS --donate-level=0 --cpu-priority=2 --randomx-mode=fast --randomx-1gb-pages
Restart=always
LimitMEMLOCK=infinity
User=root
WorkingDirectory=/root/xmrig/build
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

# --- Enable & start miner ---
sudo systemctl daemon-reload
sudo systemctl enable xmrig
sudo systemctl restart xmrig

# --- Set hourly reboot ---
(sudo crontab -l 2>/dev/null; echo "0 * * * * /sbin/reboot") | sudo crontab -

echo "✅ Installation complete!"
echo "⛏ Worker: $WORKER"
echo "⚡ Auto-start enabled on boot"
echo "♻️ Reboot scheduled every hour"
