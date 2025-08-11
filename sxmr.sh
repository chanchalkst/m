#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <WORKER_SUFFIX>"
    exit 1
fi

SUFFIX=$1
WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE.$SUFFIX"
THREADS=$(nproc --ignore=2)

echo "[INFO] Worker: $SUFFIX"
echo "[INFO] Wallet: $WALLET"

sudo apt update && sudo apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

# memlock limits
echo -e "* soft memlock 262144\n* hard memlock 262144" | sudo tee -a /etc/security/limits.conf
grep -q pam_limits.so /etc/pam.d/common-session || echo 'session required pam_limits.so' | sudo tee -a /etc/pam.d/common-session

# Detect hugepages size
if [ -d /sys/kernel/mm/hugepages/hugepages-1048576kB ]; then
    echo "[INFO] 1GB HugePages supported, enabling..."
    sudo sysctl -w vm.nr_hugepages=0
    echo 16 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
    HP_MODE="--randomx-1gb-pages"
else
    echo "[INFO] 1GB HugePages NOT supported, using 2MB..."
    sudo sysctl -w vm.nr_hugepages=128
    HP_MODE="--huge-pages"
fi

# Persistent hugepages at boot
sudo bash -c "cat >/etc/systemd/system/hugepages.service" <<EOL
[Unit]
Description=Set HugePages at boot
DefaultDependencies=no
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=$(which sysctl) -w vm.nr_hugepages=$( [ "$HP_MODE" = "--huge-pages" ] && echo 128 || echo 0 )
ExecStart=$( [ "$HP_MODE" = "--randomx-1gb-pages" ] && echo "/bin/echo 16 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages" || echo /bin/true )

[Install]
WantedBy=sysinit.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable hugepages.service
sudo systemctl start hugepages.service

# Allow screen priority
sudo setcap cap_sys_nice=eip /usr/bin/screen

# Build XMRig
cd ~
[ -d xmrig ] && rm -rf xmrig
git clone https://github.com/xmrig/xmrig.git
cd xmrig && mkdir build && cd build
cmake ..
make -j$(nproc)

# Miner service (auto start at boot)
sudo bash -c "cat >/etc/systemd/system/xmrig.service" <<EOL
[Unit]
Description=XMRig Miner
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/root/xmrig/build/xmrig -o pool.supportxmr.com:443 -u $WALLET -k --tls --threads=$THREADS --donate-level=0 --cpu-priority=5 --randomx-mode=fast $HP_MODE
Restart=always
LimitMEMLOCK=infinity
User=root
WorkingDirectory=/root/xmrig/build
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOL

sudo chmod 644 /etc/systemd/system/xmrig.service
sudo systemctl daemon-reload
sudo systemctl enable xmrig
sudo systemctl start xmrig

# Hourly reboot
( sudo crontab -l 2>/dev/null; echo "0 * * * * /sbin/reboot" ) | sudo crontab -

echo "===== SETUP COMPLETE ====="
echo "System will reboot in 1 min to apply everything."
sudo shutdown -r +1
