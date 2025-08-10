#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Please run as root or with sudo." >&2
  exit 1
fi

# Telegram bot config (optional, remove if you don't want)
TG_BOT_TOKEN="8202416073:AAGv6s9dycfPZt0hSH-9zRJC4ovmy1RjNZE"
TG_CHAT_ID="5304966667"

send_tg() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$text" > /dev/null
}

BASE_WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1JjJg3uQdY9d8ZcYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE"
WORKER_ID="${1:-A00001}"
WALLET="$BASE_WALLET.$WORKER_ID"

CPU_CORES=$(nproc)
THREADS=$(( CPU_CORES > 1 ? CPU_CORES - 1 : 1 ))

echo "Using wallet: $WALLET"
echo "Mining on $THREADS threads (CPU cores: $CPU_CORES)"

echo "Updating package lists..."
apt update -y

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
systemctl restart xmrig

echo "Scheduling reboot every 2 hours in root crontab..."
sudo crontab -l 2>/dev/null | grep -v reboot > /tmp/rootcron || true
echo "0 */2 * * * /sbin/reboot" | sudo tee -a /tmp/rootcron
sudo crontab /tmp/rootcron
rm /tmp/rootcron

echo "Verifying reboot schedule..."
if ! sudo crontab -l 2>/dev/null | grep -q '/sbin/reboot'; then
  err="❌ Reboot schedule NOT set in root crontab! Worker ID: $WORKER_ID"
  echo "$err"
  send_tg "$err"
  exit 1
fi

echo "Verifying xmrig service status..."
if ! systemctl is-enabled xmrig &>/dev/null; then
  err="❌ xmrig service is NOT enabled! Worker ID: $WORKER_ID"
  echo "$err"
  send_tg "$err"
  exit 1
fi

if ! systemctl is-active xmrig &>/dev/null; then
  err="❌ xmrig service is NOT active! Worker ID: $WORKER_ID"
  echo "$err"
  send_tg "$err"
  exit 1
fi

echo "--------------------------------------"
echo "Setup complete."
echo "Miner running with wallet: $WALLET"
echo "Reboot scheduled every 2 hours."
echo "--------------------------------------"

send_tg "✅ *Setup complete*\nMiner running with wallet: \`$WALLET\`\nReboot scheduled every 2 hours.\nWorker ID: \`$WORKER_ID\`"
