#!/bin/bash
# עדכון זרם — הפרדת קונסולת מנהל-על ואימות משתמשים.
# מריצים על הדרופלט: bash dz3.sh
set -euo pipefail
exec > >(tee -a /var/log/zerem-deploy.log) 2>&1
echo "════ עדכון זרם — אימות והפרדת קונסולה · $(date) ════"

REPO=https://raw.githubusercontent.com/avileon/zerem-deploy/main
cd /opt/zerem

# ── גיבוי לפני שינוי סכמה ──
# ⚠️ המיגרציה משנה enum ומוחקת ערכים. בלי גיבוי אין דרך חזרה.
echo "→ מגבה…"
mkdir -p /opt/backups
docker compose exec -T db pg_dump -U postgres zerem \
  | gzip > "/opt/backups/zerem-preauth-$(date +%Y%m%d-%H%M%S).sql.gz" \
  || { echo "✗ הגיבוי נכשל — עוצר"; exit 1; }
ls -1t /opt/backups/*.sql.gz | tail -n +8 | xargs -r rm
echo "✓ גיבוי נשמר"

# ── קוד ──
echo "→ מוריד קוד…"
curl -fsSL "$REPO/zerem-src.tgz" -o s.tgz
tar xzf s.tgz && rm -f s.tgz

# ── סביבה ──
IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
HOST="zerem.${IP}.sslip.io"
touch .env; chmod 600 .env
add_env() { grep -q "^$1=" .env || echo "$1=$2" >> .env; }
add_env APP_ORIGIN "https://${HOST}"
add_env SEED_CONSOLE_EMAIL "avi@vibit.co.il"
# מצב דמו — משאיר את חשבונות הבדיקה פעילים.
# להפעלה אמיתית: מחק את השורה, הרץ מחדש, וקבל קישור חד-פעמי.
add_env SEED_DEMO_PASSWORD "ZeremDemo2026!"

# ── בנייה ──
echo "→ בונה…"
docker compose up -d --build

echo "→ ממתין…"
for i in $(seq 1 80); do
  if docker exec zerem-app node -e 'fetch("http://localhost:3000/login").then(r=>process.exit(r.status<400?0:1)).catch(()=>process.exit(1))' >/dev/null 2>&1; then break; fi
  sleep 3
done

echo ""
echo "→ לוג האתחול (מיגרציה + זריעה):"
docker compose logs app 2>&1 | grep -E "מיגרצי|זורע|✓|⚠|set-password" | tail -25

# ── בדיקות שפיות ──
echo ""
echo "→ בדיקת מסלולים:"
check() {
  docker exec -e P="$1" zerem-app node -e \
    'fetch("http://localhost:3000"+process.env.P,{redirect:"manual"}).then(r=>console.log(r.status)).catch(()=>console.log("ERR"))' 2>/dev/null
}
for p in /login /console/login /pricing; do
  printf "   %-18s %s (מצופה 200)\n" "$p" "$(check $p)"
done
for p in / /leads /team /console; do
  printf "   %-18s %s (מצופה 307 — מוגן)\n" "$p" "$(check $p)"
done

echo ""
echo "═══════════════════════════════════════════"
echo "  קונסולת ניהול → https://${HOST}/console"
echo "  אפליקציית לקוח → https://${HOST}/login"
echo "  דף מחירים      → https://${HOST}/pricing"
echo "═══════════════════════════════════════════"
