#!/usr/bin/env bash
# Issue the hosted door's FoundationDB client certificate through OpenBao's PKI and hand
# it to the Fly app as the four secrets the release materialises at boot (RFD 2134 shape:
# FDB_TLS_CERT_B64, FDB_TLS_KEY_B64, FDB_TLS_CA_B64, plus WEFT_FDB_CLUSTER_B64). Needs a
# bao token that may issue on the PKI role (BAO_TOKEN, or read from 1Password), the bao
# and fly CLIs, openssl and python. Prints subjects and dates, never a key or a token.
set -euo pipefail

APP=${APP:-weftspun-taskweft-acp}
MOUNT=${BAO_PKI_MOUNT:-pki}
ROLE=${BAO_PKI_ROLE:-}
CN=${CN:-fdb-taskweft-acp.chibifire.com}
TTL=${TTL:-2160h}
SOURCE_APP=${SOURCE_APP:-weftspun-bao}
OP_ITEM=${OP_ITEM:-op://Personal/weftspun-bao root/password}
BAO=${BAO:-bao}
OP=${OP:-op}
FLY=${FLY:-fly}
PYTHON=${PYTHON:-python3}

export BAO_ADDR=${BAO_ADDR:-https://100.124.200.34:8200}
export BAO_TLS_SERVER_NAME=${BAO_TLS_SERVER_NAME:-weftspun-bao.internal}
export BAO_CACERT=${BAO_CACERT:-$HOME/.magi/ca-bundle.pem}
# The listener requires a client certificate at the TLS layer even for a token login.
export BAO_CLIENT_CERT=${BAO_CLIENT_CERT:-$HOME/.magi/v3-leaf-int.pem}
export BAO_CLIENT_KEY=${BAO_CLIENT_KEY:-$HOME/.magi/bao-client-v3.key}

if [ -z "${BAO_TOKEN:-}" ]; then
  BAO_TOKEN=$("$OP" read "$OP_ITEM" | tr -d '\r\n')
fi
export BAO_TOKEN
[ -n "$BAO_TOKEN" ] || { echo "no bao token" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The role: the one named, else the first role that may sign a client leaf under
# chibifire.com, else a new fdb-client role with RFD 2145's 90-day ceiling.
if [ -z "$ROLE" ]; then
  roles=$("$BAO" list -format=json "$MOUNT/roles" 2>&1 | tr -d '\r' || true)
  case "$roles" in
    "["*) ;;
    ""|*"No value found"*) roles="[]" ;;
    *) echo "bao list $MOUNT/roles: $roles" >&2; exit 1 ;;
  esac
  ROLE=$(printf '%s' "$roles" | "$PYTHON" -c '
import json, subprocess, sys
mount, bao = sys.argv[1], sys.argv[2]
roles = json.load(sys.stdin)
for name in sorted(roles, key=lambda n: (0 if "fdb" in n else 1, n)):
    out = subprocess.run([bao, "read", "-format=json", mount + "/roles/" + name], capture_output=True, text=True).stdout
    d = json.loads(out)["data"]
    domains = d.get("allowed_domains") or []
    if d.get("client_flag") and ("chibifire.com" in domains and d.get("allow_subdomains") or d.get("allow_any_name")):
        print(name)
        break
' "$MOUNT" "$BAO")
fi
if [ -z "$ROLE" ]; then
  ROLE=fdb-client
  "$BAO" write "$MOUNT/roles/$ROLE" allowed_domains=chibifire.com allow_subdomains=true \
    client_flag=true server_flag=true key_type=rsa key_bits=2048 max_ttl=2160h ttl=2160h >/dev/null
  echo "created role $MOUNT/roles/$ROLE"
fi
echo "role: $MOUNT/roles/$ROLE"

"$BAO" write -format=json "$MOUNT/issue/$ROLE" common_name="$CN" ttl="$TTL" | tr -d '\r' > "$work/issue.json"
"$PYTHON" - "$work" <<'EOF'
import json, os, sys
w = sys.argv[1]
d = json.load(open(os.path.join(w, "issue.json")))["data"]
open(os.path.join(w, "cert.pem"), "w").write(d["certificate"].strip() + "\n")
open(os.path.join(w, "key.pem"), "w").write(d["private_key"].strip() + "\n")
chain = d.get("ca_chain") or [d["issuing_ca"]]
open(os.path.join(w, "ca.pem"), "w").write("\n".join(c.strip() for c in chain) + "\n")
EOF
chmod 600 "$work/key.pem"
openssl x509 -in "$work/cert.pem" -noout -subject -enddate
openssl verify -CAfile "$work/ca.pem" "$work/cert.pem"

# The cluster string, from a client that already holds it, without it touching a terminal.
# flyctl on Windows exits 1 after a clean console command, so the check is on the content.
"$FLY" ssh console -a "$SOURCE_APP" -C 'sh -c "printf %s \"$FDB_CLUSTER_CONTENT\""' 2>/dev/null \
  | tr -d '\r\n' > "$work/fdb.cluster" || true
grep -q '@' "$work/fdb.cluster" || { echo "no cluster string from $SOURCE_APP" >&2; exit 1; }
coords=$(tr ',' '\n' < "$work/fdb.cluster" | wc -l | tr -d ' ')
case "$(cat "$work/fdb.cluster")" in *:tls*) tls=yes;; *) tls=no;; esac
echo "cluster string: $coords coordinator(s), tls=$tls"

"$FLY" secrets set -a "$APP" \
  FDB_TLS_CERT_B64="$(base64 -w0 "$work/cert.pem")" \
  FDB_TLS_KEY_B64="$(base64 -w0 "$work/key.pem")" \
  FDB_TLS_CA_B64="$(base64 -w0 "$work/ca.pem")" \
  WEFT_FDB_CLUSTER_B64="$(base64 -w0 "$work/fdb.cluster")" >/dev/null
echo "secrets set on $APP: FDB_TLS_CERT_B64 FDB_TLS_KEY_B64 FDB_TLS_CA_B64 WEFT_FDB_CLUSTER_B64"
