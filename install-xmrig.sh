#!/bin/bash

# Prompt for worker name
read -p "Enter a unique worker name (e.g., rig01): " WORKER_NAME

# 1. Install dependencies
sudo apt update && sudo apt install -y \
    git build-essential cmake automake libtool autoconf \
    libhwloc-dev libuv1-dev libssl-dev msr-tools

# 2. Enable Huge Pages
echo 'vm.nr_hugepages = 128' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
sudo bash -c "echo '* soft memlock 262144' >> /etc/security/limits.conf"
sudo bash -c "echo '* hard memlock 262144' >> /etc/security/limits.conf"

# 3. Enable MSR for CPU tuning
sudo modprobe msr
if ! grep -q msr /etc/modules; then echo msr | sudo tee -a /etc/modules; fi

# 4. Clone and build XMRig from GitHub
cd /opt
sudo git clone https://github.com/xmrig/xmrig.git
cd xmrig
sudo mkdir build && cd build
sudo cmake ..
sudo make -j$(nproc)

# 5. Create XMRig config with fixed wallet and user-defined worker name
sudo tee /opt/xmrig/config.json > /dev/null <<EOF
{
  "autosave": true,
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "priority": 5,
    "yield": true
  },
  "donate-level": 1,
  "log-file": null,
  "api": {
    "id": null,
    "worker-id": "$WORKER_NAME"
  },
  "pools": [
    {
      "url": "pool.supportxmr.com:443",
      "user": "42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE",
      "pass": "$WORKER_NAME",
      "keepalive": true,
      "tls": true
    }
  ]
}
EOF

# 6. Create systemd service
sudo tee /etc/systemd/system/xmrig.service > /dev/null <<EOF
[Unit]
Description=XMRig Miner
After=network.target

[Service]
ExecStart=/opt/xmrig/build/xmrig -c /opt/xmrig/config.json
WorkingDirectory=/opt/xmrig
Restart=always
RestartSec=5
LimitMEMLOCK=infinity
Nice=10
CPUWeight=100

[Install]
WantedBy=multi-user.target
EOF

# 7. Enable and start the miner
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable xmrig
sudo systemctl start xmrig

# 8. Final confirmation message
echo -e "\n✅ XMRig setup complete!"
echo "💼 Worker Name: $WORKER_NAME"
echo "💰 Mining to wallet: YOUR_FIXED_MONERO_WALLET_ADDRESS"
echo "📡 Pool: pool.supportxmr.com:443 (TLS enabled)"
echo "🛠  Service: xmrig (enabled and running)"
echo "🔍 Check status with: sudo systemctl status xmrig"
echo "📈 Monitor at: https://supportxmr.com/#worker_stats"
