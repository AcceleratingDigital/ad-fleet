#!/bin/bash
# ad-fleet-approve.sh — Review and approve pending fleet join requests
# Run on an ADMIN machine. Admin decides the role — never trusts joining machine.

CONFIG="$HOME/.ad-fleet/config.yaml"
[ ! -f "$CONFIG" ] && echo "No admin fleet config found at $CONFIG" && exit 1

DB_HOST=$(grep "db_host:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PORT=$(grep "db_port:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_USER=$(grep "db_user:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_PASS=$(grep "db_pass:" "$CONFIG" | awk '{print $2}' | tr -d '"')
DB_NAME=$(grep "db_name:" "$CONFIG" | awk '{print $2}' | tr -d '"')
APPROVER=$(grep "hostname:" "$CONFIG" | awk '{print $2}' | tr -d '"')

export PGPASSWORD="$DB_PASS"

echo "=== Pending Fleet Join Requests ==="
echo ""

# Get all pending request IDs
REQUEST_IDS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
  "SELECT id FROM hermes_bus
   WHERE to_host = 'fleet-admin'
     AND status = 'pending'
     AND body LIKE '%join_request%'
   ORDER BY created_at ASC;" 2>/dev/null)

if [ -z "$REQUEST_IDS" ]; then
  echo "No pending join requests."
  exit 0
fi

for REQ_ID in $REQUEST_IDS; do
  # Get each field separately to avoid pipe-delimiter issues with JSON
  FROM_HOST=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT from_host FROM hermes_bus WHERE id = $REQ_ID;" 2>/dev/null)
  BODY=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT body FROM hermes_bus WHERE id = $REQ_ID;" 2>/dev/null)
  CREATED_AT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT created_at FROM hermes_bus WHERE id = $REQ_ID;" 2>/dev/null)

  # Parse JSON fields
  REQ_HOSTNAME=$(echo "$BODY" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('hostname','?'))" 2>/dev/null)
  REQ_USER=$(echo "$BODY"     | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('user','?'))" 2>/dev/null)
  REQ_TEAM=$(echo "$BODY"     | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('team','?'))" 2>/dev/null)
  REQ_CLASS=$(echo "$BODY"    | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('classification','transient'))" 2>/dev/null)
  REQ_UUID=$(echo "$BODY"     | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('uuid','?'))" 2>/dev/null)

  echo "------------------------------------"
  echo "  Machine: $REQ_HOSTNAME"
  echo "  User:    $REQ_USER ($REQ_TEAM)"
  echo "  Type:    $REQ_CLASS"
  echo "  UUID:    $REQ_UUID"
  echo "  Sent:    $CREATED_AT"
  echo ""
  read -r -p "  Approve? [y/n/s=skip]: " DECISION

  DECISION_LOWER=$(echo "$DECISION" | tr '[:upper:]' '[:lower:]')

  if [ "$DECISION_LOWER" = "y" ] || [ "$DECISION_LOWER" = "yes" ]; then
    # Admin assigns the role — machine's requested role is ignored
    read -r -p "  Role [M=member / A=admin, default M]: " ROLE_INPUT
    ROLE_UPPER=$(echo "$ROLE_INPUT" | tr '[:lower:]' '[:upper:]')
    if [ "$ROLE_UPPER" = "A" ]; then
      APPROVED_ROLE="admin"
      DISPLAY_ROLE="admin"
    else
      APPROVED_ROLE="writer"
      DISPLAY_ROLE="member"
    fi

    # Register in fleet_directives
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
      "INSERT INTO fleet_directives (host, role, classification, team, registered_by, registered_at)
       VALUES ('$REQ_HOSTNAME', '$APPROVED_ROLE', '$REQ_CLASS', '$REQ_TEAM', '$REQ_USER', NOW())
       ON CONFLICT (host) DO UPDATE
       SET role='$APPROVED_ROLE', classification='$REQ_CLASS', team='$REQ_TEAM';" 2>/dev/null

    # Notify machine of approval + assigned role
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
      "INSERT INTO hermes_bus (from_host, to_host, kind, body, task_title, task_expires_at)
       VALUES ('$APPROVER', '$REQ_HOSTNAME', 'msg',
         '{\"task\":\"join_approved\",\"approved_by\":\"$APPROVER\",\"role\":\"$APPROVED_ROLE\"}',
         'Fleet join APPROVED — role: $DISPLAY_ROLE',
         NOW() + INTERVAL '24 hours');" 2>/dev/null

    # Mark request done
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
      "UPDATE hermes_bus SET status='done', result='Approved as $DISPLAY_ROLE by $APPROVER', done_at=NOW()
       WHERE id=$REQ_ID;" 2>/dev/null

    echo "  ✅ $REQ_HOSTNAME approved as $DISPLAY_ROLE"

  elif [ "$DECISION_LOWER" = "n" ] || [ "$DECISION_LOWER" = "no" ]; then
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -q -c \
      "UPDATE hermes_bus SET status='done', result='Rejected by $APPROVER', done_at=NOW()
       WHERE id=$REQ_ID;" 2>/dev/null
    echo "  ❌ $REQ_HOSTNAME rejected"
  else
    echo "  ⏭️  Skipped"
  fi
  echo ""
done

echo "=== Done ==="
