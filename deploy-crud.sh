#!/bin/bash
# עדכון זרם — CRUD + מעבר למיגרציות. הפריסה האחרונה בשיטת הטארבול.
# מכאן והלאה: /opt/zerem/update.sh דרך git.
set -euo pipefail
exec > >(tee -a /var/log/zerem-deploy.log) 2>&1
echo "════ עדכון זרם · $(date) ════"

REPO=https://raw.githubusercontent.com/avileon/zerem-deploy/main
cd /opt/zerem

# ── גיבוי ──
echo "→ מגבה…"
mkdir -p /opt/backups
BACKUP="/opt/backups/zerem-precrud-$(date +%Y%m%d-%H%M%S).sql.gz"
docker compose exec -T db pg_dump -U postgres zerem | gzip > "$BACKUP" \
  || { echo "✗ הגיבוי נכשל — עוצר"; exit 1; }
echo "✓ $BACKUP ($(du -h "$BACKUP" | cut -f1))"
ls -1t /opt/backups/*.sql.gz | tail -n +15 | xargs -r rm

# ── קוד ──
echo "→ מוריד קוד…"
curl -fsSL "$REPO/zerem-src.tgz" -o s.tgz
tar xzf s.tgz && rm -f s.tgz
chmod +x deploy/*.sh 2>/dev/null || true
# מעתיקים לשורש כדי שיהיו נוחים להרצה
cp -f deploy/update.sh deploy/rollback.sh deploy/setup-git.sh . 2>/dev/null || true
chmod +x update.sh rollback.sh setup-git.sh 2>/dev/null || true

# ── סביבה ──
IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
HOST="zerem.${IP}.sslip.io"
touch .env; chmod 600 .env
grep -q '^APP_ORIGIN=' .env || echo "APP_ORIGIN=https://${HOST}" >> .env

# ── בנייה ──
echo "→ בונה…"
docker compose up -d --build

echo "→ ממתין…"
for i in $(seq 1 80); do
  if docker exec zerem-app node -e 'fetch("http://localhost:3000/login").then(r=>process.exit(r.status<400?0:1)).catch(()=>process.exit(1))' >/dev/null 2>&1; then break; fi
  sleep 3
done

echo ""
echo "→ לוג אתחול:"
docker compose logs app --tail 50 2>&1 | grep -E "מיגרצי|זורע|מסנכרן|baseline|✓|⚠|✗" | tail -14

# ── בדיקות ──
echo ""
echo "→ בדיקות אוטומטיות:"
docker exec zerem-app npx tsx src/db/security-test.ts http://localhost:3000 2>&1 | tail -3
docker exec zerem-app npx tsx src/db/crud-test.ts     http://localhost:3000 2>&1 | tail -3

ORGS=$(docker compose exec -T db psql -U postgres zerem -tAc "SELECT count(*) FROM organizations" | tr -d ' ')
LEADS=$(docker compose exec -T db psql -U postgres zerem -tAc "SELECT count(*) FROM leads" | tr -d ' ')
MIGR=$(docker compose exec -T db psql -U postgres zerem -tAc "SELECT count(*) FROM drizzle.__drizzle_migrations" 2>/dev/null | tr -d ' ')

echo ""
echo "═══════════════════════════════════════════"
echo "  ✅ $ORGS עסקים · $LEADS לידים · $MIGR מיגרציות"
echo "  אפליקציה → https://${HOST}/login"
echo "  קונסולה  → https://${HOST}/console"
echo ""
echo "  מעבר ל-git (פעם אחת):"
echo "    /opt/zerem/setup-git.sh git@github.com:USER/REPO.git"
echo "  עדכון מכאן והלאה:"
echo "    /opt/zerem/update.sh"
echo "═══════════════════════════════════════════"
