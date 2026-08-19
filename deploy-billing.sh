#!/bin/bash
# עדכון זרם עם מודול הגבייה + התקנת ה-cron היומי.
# מריצים על הדרופלט: bash dz2.sh
set -euo pipefail
exec > >(tee -a /var/log/zerem-deploy.log) 2>&1
echo "════ עדכון זרם — מודול גבייה · $(date) ════"

REPO=https://raw.githubusercontent.com/avileon/zerem-deploy/main
cd /opt/zerem

# ── גיבוי מסד הנתונים לפני שינוי סכמה ──
echo "→ מגבה את מסד הנתונים…"
mkdir -p /opt/backups
docker compose exec -T db pg_dump -U postgres zerem \
  | gzip > "/opt/backups/zerem-$(date +%Y%m%d-%H%M%S).sql.gz" || echo "⚠ הגיבוי נכשל — ממשיכים בכל זאת"
ls -1t /opt/backups/*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm    # שומרים 7 אחרונים

# ── משיכת הקוד ──
echo "→ מוריד קוד…"
curl -fsSL "$REPO/zerem-src.tgz" -o s.tgz
tar xzf s.tgz && rm -f s.tgz

# ── משתני סביבה ──
IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
HOST="zerem.${IP}.sslip.io"

touch .env
add_env() {  # add_env KEY VALUE  — לא דורס ערך קיים
  grep -q "^$1=" .env || echo "$1=$2" >> .env
}
add_env APP_ORIGIN "https://${HOST}"
add_env CRON_SECRET "$(openssl rand -hex 24)"
add_env PLATFORM_CARDCOM_TERMINAL 1000
add_env PLATFORM_CARDCOM_API_NAME Cardcomtest26
add_env PLATFORM_CARDCOM_ZERO_AUTH true
chmod 600 .env
echo "✓ .env מוכן"

# ── בנייה ──
echo "→ בונה…"
docker compose up -d --build

echo "→ ממתין לאפליקציה…"
for i in $(seq 1 60); do
  if docker exec zerem-app node -e 'fetch("http://localhost:3000/").then(()=>process.exit(0)).catch(()=>process.exit(1))' >/dev/null 2>&1; then break; fi
  sleep 3
done

# ── ה-cron היומי ──
# 03:00 שעון ישראל. הקריאה עוברת דרך run-billing.sh שמריץ node fetch
# בתוך הקונטיינר — לתמונת node:alpine אין wget, וזה הפיל את הגרסה הראשונה.
install -m 755 /opt/zerem/run-billing.sh /opt/zerem/run-billing.sh 2>/dev/null || true
chmod +x /opt/zerem/run-billing.sh
cat > /etc/cron.d/zerem-billing <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
CRON_TZ=Asia/Jerusalem
0 3 * * * root /opt/zerem/run-billing.sh >> /var/log/zerem-billing.log 2>&1
EOF
chmod 644 /etc/cron.d/zerem-billing
service cron reload 2>/dev/null || systemctl reload cron 2>/dev/null || true
echo "✓ cron יומי הותקן — 03:00 שעון ישראל"

# ── בדיקה ──
echo ""
echo "→ בדיקת מסלולים:"
for p in / /pricing /settings/billing /admin/revenue /admin/coupons; do
  CODE=$(docker exec -e P="$p" zerem-app node -e \
    'fetch("http://localhost:3000"+process.env.P).then(r=>console.log(r.status)).catch(()=>console.log("ERR"))' 2>/dev/null || echo "ERR")
  printf "   %-22s %s\n" "$p" "${CODE:-ERR}"
done

echo ""
echo "→ הרצת מחזור יבשה (dryRun — לא מחייב כלום):"
SECRET=$(grep '^CRON_SECRET=' /opt/zerem/.env | cut -d= -f2-)
docker exec -e U="http://localhost:3000/api/cron/billing?dryRun=1" -e A="Bearer $SECRET" zerem-app \
  node -e 'fetch(process.env.U,{method:"POST",headers:{Authorization:process.env.A}}).then(r=>r.text()).then(console.log).catch(e=>console.log("ERR",String(e)))'

echo ""
echo "═══════════════════════════════════════"
echo "  זרם  → https://${HOST}"
echo "  מחירים → https://${HOST}/pricing"
echo "  חיוב   → https://${HOST}/settings/billing"
echo "  ניהול  → https://${HOST}/admin/revenue"
echo "═══════════════════════════════════════"
