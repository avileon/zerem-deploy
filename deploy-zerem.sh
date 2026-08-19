#!/bin/bash
# פריסת זרם לצד Kesher על אותו דרופלט. ללא טוקן — מושך מריפו ציבורי.
set -euo pipefail
exec > >(tee -a /var/log/zerem-deploy.log) 2>&1

IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
echo "→ IP: $IP"

docker network create web 2>/dev/null || echo "✓ רשת web קיימת"

# ── קוד ──
mkdir -p /opt/zerem && cd /opt/zerem
curl -fsSL https://raw.githubusercontent.com/avileon/zerem-deploy/main/zerem-src.tgz -o s.tgz
tar xzf s.tgz && rm -f s.tgz

rnd() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
[ -f .env ] || { printf 'POSTGRES_PASSWORD=%s\n' "$(rnd 24)" > .env; chmod 600 .env; }

echo "→ בונה את זרם (5-10 דקות)…"
docker compose up -d --build

# ── חיבור Caddy הקיים לשני האתרים ──
python3 - <<'PY'
p = '/opt/kesher/docker-compose.yml'
s = open(p).read()
if 'networks: [default, web]' not in s:
    s = s.replace('      - caddy_config:/config',
                  '      - caddy_config:/config\n    networks: [default, web]', 1)
if '\nnetworks:' not in s:
    s = s.rstrip() + '\n\nnetworks:\n  web:\n    external: true\n'
open(p, 'w').write(s)
print('✓ compose עודכן')
PY

cat > /opt/kesher/Caddyfile <<EOF
kesher.${IP}.sslip.io {
	encode gzip
	reverse_proxy app:3000
}

zerem.${IP}.sslip.io {
	encode gzip
	reverse_proxy zerem-app:3000
}

${IP}.sslip.io {
	redir https://zerem.${IP}.sslip.io{uri} temporary
}
EOF

cd /opt/kesher
docker compose up -d
docker compose restart caddy

echo ""
echo "═══════════════════════════════════════"
echo "  זרם   → https://zerem.${IP}.sslip.io"
echo "  Kesher → https://kesher.${IP}.sslip.io"
echo "═══════════════════════════════════════"
