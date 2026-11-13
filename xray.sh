#!/bin/bash
# Xray + Cloudflared Tunnel — Replit uyumlu
# apt/sudo yok, her şey çalışma dizininde

set -e

echo "=== Xray + Cloudflared Tunnel Başlatılıyor ==="

# --- 1. Eski process'leri temizle ---
pkill -f "xray run" 2>/dev/null || true
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1

# --- 2. Xray binary indir (varsa atla) ---
if [ ! -x ./xray ]; then
    echo "📥 Xray binary indiriliyor..."
    wget -q https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -O Xray.zip
    unzip -oq Xray.zip
    chmod +x xray
    rm -f Xray.zip
fi
echo "✅ Xray: $(./xray version | head -1)"

# --- 3. UUID ---
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
echo "✅ UUID: $UUID"

# --- 4. Optimize edilmiş config ---
echo "📝 config.json oluşturuluyor..."
cat << EOF > config.json
{
  "log": {"loglevel": "warning"},
  "policy": {
    "levels": {
      "0": {
        "bufferSize": 4,
        "handshake": 10,
        "connIdle": 120
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false
    }
  },
  "inbounds": [{
    "port": 10000,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "${UUID}"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {"path": "/"}
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

# --- 5. Xray başlat ---
echo "🚀 Xray başlatılıyor..."
export GOGC=50
export GOMEMLIMIT=400MiB
nohup ./xray run -config config.json > xray.log 2>&1 &
sleep 3

if ! pgrep -f "xray run" > /dev/null; then
    echo "❌ Xray başlatılamadı! Log:"
    cat xray.log
    exit 1
fi
echo "✅ Xray çalışıyor (PID: $(pgrep -f 'xray run' | tr '\n' ' '))"

# --- 6. Cloudflared indir ---
if [ ! -x ./cloudflared ]; then
    echo "📥 Cloudflared indiriliyor..."
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O cloudflared
    chmod +x cloudflared
fi
echo "✅ Cloudflared: $(./cloudflared --version 2>&1 | head -1)"

# --- 7. Cloudflared tunnel (HTTP2) ---
echo "🔗 Cloudflared tunnel başlatılıyor (HTTP2)..."
: > tunnel.log
nohup ./cloudflared tunnel --url http://127.0.0.1:10000 --protocol http2 > tunnel.log 2>&1 &

echo "⏳ 20 saniye bekleniyor..."
sleep 20

TUNNEL_URL=$(grep -ao 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' tunnel.log | head -1)
if [ -z "$TUNNEL_URL" ]; then
    echo "❌ Tunnel URL bulunamadı! Loglar:"
    cat tunnel.log
    exit 1
fi
echo "✅ Tunnel URL: $TUNNEL_URL"

# --- 8. VLESS URL ---
HOST=$(echo "$TUNNEL_URL" | sed 's|https://||')
VLESS_URL="vless://${UUID}@${HOST}:443?path=/&security=tls&encryption=none&host=${HOST}&type=ws#Xray-Tunnel"
ENCODED=$(echo -n "$VLESS_URL" | base64 -w 0 2>/dev/null || echo -n "$VLESS_URL" | base64)

echo "$VLESS_URL" > vless-url.txt
echo "$TUNNEL_URL" > tunnel-url.txt

echo "=========================================="
echo "✅ VLESS URL OLUŞTURULDU!"
echo "=========================================="
echo "🔗 Tunnel: $TUNNEL_URL"
echo "📱 VLESS:  $VLESS_URL"
echo "📱 QR:     https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=$ENCODED"
echo "📁 Dosyalar: vless-url.txt, tunnel-url.txt"
echo "=========================================="

# --- 9. Canlı tutma + otomatik restart ---
echo ""
echo "⏳ Çalışıyor. Durdurmak için Ctrl+C"
echo "=========================================="

while true; do
    sleep 60

    # Cloudflared kontrol + restart
    if ! pgrep -f "cloudflared tunnel" > /dev/null; then
        echo "❌ Cloudflared durdu! Yeniden başlatılıyor..."
        : > tunnel.log
        nohup ./cloudflared tunnel --url http://127.0.0.1:10000 --protocol http2 > tunnel.log 2>&1 &
        sleep 20
        NEW_URL=$(grep -ao 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' tunnel.log | head -1)
        if [ -n "$NEW_URL" ]; then
            TUNNEL_URL="$NEW_URL"
            HOST=$(echo "$TUNNEL_URL" | sed 's|https://||')
            VLESS_URL="vless://${UUID}@${HOST}:443?path=/&security=tls&encryption=none&host=${HOST}&type=ws#Xray-Tunnel"
            echo "$VLESS_URL" > vless-url.txt
            echo "$TUNNEL_URL" > tunnel-url.txt
            echo "🔄 Yeni VLESS: $VLESS_URL"
        fi
    fi

    # Xray kontrol + restart
    if ! pgrep -f "xray run" > /dev/null; then
        echo "❌ Xray durdu! Yeniden başlatılıyor..."
        export GOGC=50
        export GOMEMLIMIT=400MiB
        nohup ./xray run -config config.json > xray.log 2>&1 &
        sleep 3
    fi

    # Kaynak logu
    XRAY_PID=$(pgrep -f "xray run" | head -1)
    if [ -n "$XRAY_PID" ]; then
        echo "[$(date +%H:%M)] Xray CPU/RAM: $(ps -o pcpu,pmem -p $XRAY_PID --no-headers 2>/dev/null)"
    fi
done
