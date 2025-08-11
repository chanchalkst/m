#!/bin/bash
set -e

WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8cYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE.H00022"
THREADS=$(nproc --ignore=2)

echo "Updating packages and installing dependencies..."
sudo apt update
sudo apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

echo "Setting memlock limits..."
echo -e "* soft memlock 262144\n* hard memlock 262144" | sudo tee -a /etc/security/limits.conf
if ! grep -q pam_limits.so /etc/pam.d/common-session; then
  echo 'session required pam_limits.so' | sudo tee -a /etc/pam.d/common-session
fi

echo "Creating hugepages setup script..."
sudo tee /usr/local/sbin/set_hugepages.sh > /dev/null << 'EOF'
#!/bin/bash
set -e

echo "Trying to set 1GB hugepages..."
if sudo sysctl -w vm.nr_hugepages_1048576kB=16; then
  echo "1GB HugePages set successfully."
  sudo sysctl -w vm.nr_hugepages=0
else
  echo "1GB HugePages failed or unavailable. Trying 2MB hugepages..."
  sudo sysctl -w vm.nr_hugepages=4096
  sudo sysctl -w vm.nr_hugepages_1048576kB=0
fi

echo "Current HugePages settings:"
sysctl vm.nr_hugepages vm.nr_hugepages_1048576kB
EOF

sudo chmod +x /usr/local/sbin/set_hugepages.sh

echo "Creating systemd service for hugepages..."
sudo tee /etc/systemd/system/hugepages.service > /dev/null << EOF
[Unit]
Description=Set HugePages count

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/set_hugepages.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd and enabling hugepages service..."
sudo systemctl daemon-reload
sudo systemctl enable hugepages.service
sudo systemctl start hugepages.service

echo "Setting screen capabilities..."
sudo setcap cap_sys_nice=eip /usr/bin/screen

echo "Cloning and building XMRig miner..."
cd ~
if [ -d xmrig ]; then rm -rf xmrig; fi
git clone https://github.com/xmrig/xmrig.git
cd xmrig
mkdir -p build
cd build
cmake ..
make -j$(nproc)

echo "Creating systemd service for xmrig miner..."
sudo tee /etc/systemd/system/xmrig.service > /dev/null << EOF
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
sudo systemctl enable xmrig.service
sudo systemctl start xmrig.service

echo "Setting up hourly reboot cron job..."
(sudo crontab -l 2>/dev/null; echo "0 * * * * /sbin/reboot") | sudo crontab -

echo "=========================="
echo "Installation complete!"
echo
echo "HugePages status:"
sysctl vm.nr_hugepages vm.nr_hugepages_1048576kB
echo
echo "XMRig miner status:"
systemctl is-active xmrig.service && echo "✅ xmrig miner is running" || echo "❌ xmrig miner is NOT running"
echo
echo "HugePages service status:"
systemctl is-active hugepages.service && echo "✅ hugepages.service is running" || echo "❌ hugepages.service is NOT running"
echo
echo "Auto reboot cron job set (hourly)."
echo "=========================="
