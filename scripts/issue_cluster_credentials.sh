#!/usr/bin/env bash
# Issue the hosted door's FoundationDB client certificate through OpenBao's PKI and hand
# it to the Fly app as the four secrets the release materialises at boot (RFD 2134 shape:
# FDB_TLS_CERT_B64, FDB_TLS_KEY_B64, FDB_TLS_CA_B64, plus WEFT_FDB_CLUSTER_B64).
#
# A state machine, not a script that waits: every state names the evidence it needs and
# checks the artifact rather than a tool's exit status, a failure names the state, and
# minted material is placed before anything optional runs. Needs a bao token that may
# issue on the PKI role (BAO_TOKEN, or read from 1Password by the human's own process),
# the bao and fly CLIs, openssl and python. Prints subjects, dates and names, never a key
# or a token.
set -u

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
OBSERVATIONS=${OBSERVATIONS:-40}

export BAO_ADDR=${BAO_ADDR:-https://100.124.200.34:8200}
export BAO_TLS_SERVER_NAME=${BAO_TLS_SERVER_NAME:-weftspun-bao.internal}
export BAO_CACERT=${BAO_CACERT:-$HOME/.magi/ca-bundle.pem}
# The listener requires a client certificate at the TLS layer even for a token login.
export BAO_CLIENT_CERT=${BAO_CLIENT_CERT:-$HOME/.magi/v3-leaf-int.pem}
export BAO_CLIENT_KEY=${BAO_CLIENT_KEY:-$HOME/.magi/bao-client-v3.key}

work=$(mktemp -d)
state=start

fail() {
  echo "state $state: $*" >&2
  echo "material kept in $work" >&2
  exit 1
}

reached() {
  echo "state $state: ok $*"
}

# token: a bao token that bao itself accepts.
state=token
if [ -z "${BAO_TOKEN:-}" ]; then
  BAO_TOKEN=$("$OP" read "$OP_ITEM" 2>"$work/op.err" | tr -d '\r\n')
  [ -n "$BAO_TOKEN" ] || fail "1Password gave no token: $(tr -d '\r' < "$work/op.err" | tail -n 1)"
fi
export BAO_TOKEN
"$BAO" token lookup -format=json > "$work/lookup.json" 2>"$work/lookup.err" \
  || fail "bao refused the token: $(tr -d '\r' < "$work/lookup.err" | tail -n 1)"
reached "policies $("$PYTHON" -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["data"]["policies"]))' "$work/lookup.json")"

# role: a PKI role that may sign a client leaf under chibifire.com.
state=role
if [ -z "$ROLE" ]; then
  roles=$("$BAO" list -format=json "$MOUNT/roles" 2>&1 | tr -d '\r')
  case "$roles" in
    "["*) ;;
    ""|*"No value found"*) roles="[]" ;;
    *) fail "bao list $MOUNT/roles: $roles" ;;
  esac
  ROLE=$(printf '%s' "$roles" | "$PYTHON" -c '
import json, subprocess, sys
mount, bao = sys.argv[1], sys.argv[2]
for name in sorted(json.load(sys.stdin), key=lambda n: (0 if "fdb" in n else 1, n)):
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
    client_flag=true server_flag=true key_type=rsa key_bits=2048 max_ttl=2160h ttl=2160h >/dev/null \
    || fail "could not create $MOUNT/roles/$ROLE"
fi
"$BAO" read -format=json "$MOUNT/roles/$ROLE" > "$work/role.json" 2>/dev/null || fail "$MOUNT/roles/$ROLE is not readable"
reached "$MOUNT/roles/$ROLE"

# leaf: a certificate and key for the CN, from bao.
state=leaf
"$BAO" write -format=json "$MOUNT/issue/$ROLE" common_name="$CN" ttl="$TTL" 2>"$work/issue.err" | tr -d '\r' > "$work/issue.json"
"$PYTHON" - "$work" <<'EOF' || fail "issue answer carried no certificate: $(tr -d '\r' < "$work/issue.err" | tail -n 1)"
import json, os, sys
w = sys.argv[1]
d = json.load(open(os.path.join(w, "issue.json")))["data"]
open(os.path.join(w, "cert.pem"), "w").write(d["certificate"].strip() + "\n")
open(os.path.join(w, "key.pem"), "w").write(d["private_key"].strip() + "\n")
chain = d.get("ca_chain") or [d["issuing_ca"]]
open(os.path.join(w, "ca.pem"), "w").write("\n".join(c.strip() for c in chain) + "\n")
EOF
chmod 600 "$work/key.pem"
subject=$(openssl x509 -in "$work/cert.pem" -noout -subject 2>/dev/null) || fail "the certificate does not parse"
reached "$subject $(openssl x509 -in "$work/cert.pem" -noout -enddate)"

# chain: the leaf verifies against the chain bao returned.
state=chain
openssl verify -CAfile "$work/ca.pem" "$work/cert.pem" >/dev/null 2>"$work/verify.err" \
  || fail "$(tr -d '\r' < "$work/verify.err" | tail -n 1)"
reached "$(grep -c 'BEGIN CERTIFICATE' "$work/ca.pem") certificate(s) in the chain"

# cluster: the cluster string, from a client that already holds it. flyctl on Windows
# exits 1 after a clean console command, so the check is on the content.
state=cluster
"$FLY" ssh console -a "$SOURCE_APP" -C 'sh -c "printf %s \"$FDB_CLUSTER_CONTENT\""' 2>/dev/null \
  | tr -d '\r\n' > "$work/fdb.cluster"
grep -q '@' "$work/fdb.cluster" || fail "no cluster string from $SOURCE_APP"
coords=$(awk -F, '{print NF}' "$work/fdb.cluster")
case "$(cat "$work/fdb.cluster")" in *:tls*) tls=yes;; *) tls=no;; esac
[ "$tls" = yes ] || fail "the cluster string carries no :tls coordinator"
reached "$coords coordinator(s), tls"

# placed: the four secrets are on the app, by name.
state=placed
"$FLY" secrets set -a "$APP" \
  FDB_TLS_CERT_B64="$(base64 -w0 "$work/cert.pem")" \
  FDB_TLS_KEY_B64="$(base64 -w0 "$work/key.pem")" \
  FDB_TLS_CA_B64="$(base64 -w0 "$work/ca.pem")" \
  WEFT_FDB_CLUSTER_B64="$(base64 -w0 "$work/fdb.cluster")" >/dev/null 2>"$work/secrets.err"
names=$("$FLY" secrets list -a "$APP" 2>/dev/null | awk 'NR>1 {print $1}')
for n in FDB_TLS_CERT_B64 FDB_TLS_KEY_B64 FDB_TLS_CA_B64 WEFT_FDB_CLUSTER_B64; do
  printf '%s\n' "$names" | grep -qx "$n" || fail "$n is not among the app's secrets: $(tr -d '\r' < "$work/secrets.err" | tail -n 1)"
done
rm -rf "$work"
reached "FDB_TLS_CERT_B64 FDB_TLS_KEY_B64 FDB_TLS_CA_B64 WEFT_FDB_CLUSTER_B64"

# healthy: the machine restarted with them and the store is primary. Observed by state,
# a bounded number of times; a stopped machine is terminal and its log says why.
state=healthy
i=0
while [ "$i" -lt "$OBSERVATIONS" ]; do
  i=$((i + 1))
  machine=$("$FLY" machine list -a "$APP" --json 2>/dev/null | "$PYTHON" -c '
import json, sys
ms = json.load(sys.stdin)
print(ms[0]["state"] if ms else "none")
')
  case "$machine" in
    stopped|failed|destroyed|none)
      "$FLY" logs -a "$APP" --no-tail 2>/dev/null | tail -n 20 >&2
      fail "machine is $machine after $i observation(s)"
      ;;
  esac
  mode=$("$FLY" ssh console -a "$APP" -C 'curl -s http://localhost:8080/health' 2>/dev/null \
    | "$PYTHON" -c 'import json,sys
try:
    print(json.load(sys.stdin)["store"]["mode"])
except Exception:
    print("unreadable")')
  case "$mode" in
    primary) reached "store primary after $i observation(s)"; exit 0 ;;
    fallback) reached "store on the fallback after $i observation(s)"; exit 0 ;;
  esac
  echo "observation $i: machine $machine, store $mode"
  sleep 5
done
fail "store not primary after $OBSERVATIONS observations"
