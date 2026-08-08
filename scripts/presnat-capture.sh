#!/usr/bin/env bash
# presnat-capture.sh — capture PRE-SNAT traffic (real client IPs) for a Service across nodes.
#
# Pre-SNAT lives in each node's HOST netns. The data path is the LB VIP:servicePort (for a
# floating-IP LoadBalancer, e.g. Azure) or the nodePort otherwise — the script discovers the
# VIP, service ports and nodePorts and filters for both. It runs `kubectl debug node/<n>` (host
# netns, --profile=sysadmin) across nodes with the network-debug-toolbox image (NON-ROOT via
# tcpdump file caps); debugger pods are created in the watched Service's namespace.
#
# Usage:
#   ./presnat-capture.sh -c CONTEXT -n NAMESPACE -s SERVICE [options]
#
#   -c CONTEXT    kube context (required)
#   -n NAMESPACE  service namespace (required; debugger pods land here too)
#   -s SERVICE    LoadBalancer/NodePort service name (required)
#   -P PORT       only this Service port (.spec.ports[].port), e.g. 8080 (default: all ports)
#   -x EXPR       extra BPF expression AND-ed in, e.g. 'not host 168.63.129.16' (drop LB probes)
#   -E            only nodes that host the Service's endpoints (pods).
#                 NOTE: complete only for externalTrafficPolicy=Local. For =Cluster the LB
#                 can hit ANY node, so -E will MISS pre-SNAT traffic — use all nodes there.
#   -p POOL       only nodes with label agentpool=POOL (ignored if -E)
#   -d SECONDS    capture duration (default 20)
#   -m MODE       text | pcap (default text)
#   -i IMAGE      debug image (default: $IMG env, else <registry>/<user>/network-debug-toolbox)
#   -o OUTDIR     pcap output dir (pcap mode; default ./presnat-capture)
#   -h            help
set -euo pipefail

CTX=""; NS=""; SVC=""; POOL=""; PFILTER=""; XFILTER=""; SECS=20; MODE=text; OUT=""; SCOPE=all
IMG="${IMG:-your-registry.example.com/network-debug-toolbox:latest}"
CNAME=presnat

while getopts "c:n:s:P:x:Ep:d:m:i:o:h" opt; do
  case "$opt" in
    c) CTX=$OPTARG ;; n) NS=$OPTARG ;; s) SVC=$OPTARG ;; P) PFILTER=$OPTARG ;; x) XFILTER=$OPTARG ;; E) SCOPE=endpoints ;;
    p) POOL=$OPTARG ;; d) SECS=$OPTARG ;; m) MODE=$OPTARG ;; i) IMG=$OPTARG ;; o) OUT=$OPTARG ;;
    h) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) exit 2 ;;
  esac
done
[ -n "$CTX" ] && [ -n "$NS" ] && [ -n "$SVC" ] || { echo "ERROR: -c, -n and -s are required (-h for help)"; exit 2; }

k() { kubectl --context "$CTX" "$@"; }

# 1) VIP + externalTrafficPolicy + all ports (protocol nodePort servicePort)
VIP=$(k -n "$NS" get svc "$SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
ETP=$(k -n "$NS" get svc "$SVC" -o jsonpath='{.spec.externalTrafficPolicy}' 2>/dev/null || true)
ETP=${ETP:-Cluster}
PORTS=$(k -n "$NS" get svc "$SVC" \
  -o jsonpath='{range .spec.ports[*]}{.protocol}{" "}{.nodePort}{" "}{.port}{"\n"}{end}' 2>/dev/null || true)

# Build a filter that catches the data path whether the LB uses floating IP (data on the
# VIP:servicePort, e.g. AKS LoadBalancer) or a plain nodePort (data on the nodePort). The
# nodePort term also catches the LB health probe — drop it with -x "not host 168.63.129.16".
FILTER=""; PORTLIST=""
while read -r proto nport sport; do
  [ -n "${sport:-}" ] || continue
  [ -z "$PFILTER" ] || [ "$sport" = "$PFILTER" ] || continue
  p=$(printf '%s' "$proto" | tr 'A-Z' 'a-z')           # TCP -> tcp
  term=""
  [ -n "$VIP" ] && term="(host $VIP and $p port $sport)"        # floating-IP / VIP data path
  if [ -n "${nport:-}" ]; then
    np="($p port $nport)"                                       # nodePort path (+ health probe)
    if [ -n "$term" ]; then term="$term or $np"; else term="$np"; fi
  fi
  [ -n "$term" ] || continue
  [ -z "$FILTER" ] || FILTER="$FILTER or "
  FILTER="$FILTER($term)"
  PORTLIST="$PORTLIST ${p}:svc${sport}/np${nport:-?}"
done <<< "$PORTS"
[ -n "$FILTER" ] || { echo "ERROR: $NS/$SVC has no usable ports (ClusterIP, or bad -P value)"; exit 1; }
[ -z "$XFILTER" ] || FILTER="($FILTER) and ($XFILTER)"
echo ">> $NS/$SVC  externalTrafficPolicy=$ETP  VIP=${VIP:-<none>}"
echo ">> ports (svc/nodePort):$PORTLIST"
echo ">> bpf filter: $FILTER"

# 2) node selection
if [ "$SCOPE" = endpoints ]; then
  NODES=$(k -n "$NS" get endpointslices -l "kubernetes.io/service-name=$SVC" \
    -o jsonpath='{range .items[*].endpoints[*]}{.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | grep . || true)
  echo ">> scope: endpoint nodes ($(printf '%s ' $NODES))"
  if [ "$ETP" = "Cluster" ]; then
    echo "!! WARNING: etp=Cluster — the LB can deliver to ANY node then SNAT-forward to a pod."
    echo "!!          Endpoint-node scoping MISSES pre-SNAT traffic that arrived on other nodes."
    echo "!!          It is only complete for etp=Local. Drop -E to capture on all nodes."
  fi
elif [ -n "$POOL" ]; then
  NODES=$(k get nodes -l "agentpool=$POOL" -o name | sed 's#node/##')
else
  NODES=$(k get nodes -o name | sed 's#node/##')
fi
NCOUNT=$(printf '%s\n' "$NODES" | grep -c . || true)
[ "$NCOUNT" -gt 0 ] || { echo "ERROR: no nodes matched"; exit 1; }
echo ">> capturing on $NCOUNT node(s) for ${SECS}s, mode=$MODE, ns=$NS, image=$IMG"

# always clean up the node-debugger pods we created (in the watched namespace)
cleanup() {
  echo ">> cleanup: deleting node-debugger pods in $NS"
  local P; P=$(k -n "$NS" get pods -o name 2>/dev/null | grep node-debugger || true)
  [ -n "$P" ] && k -n "$NS" delete $P >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ "$MODE" = "text" ]; then
  # robust: --attach=false never hangs; OutOfpods nodes just yield no logs
  for n in $NODES; do
    k -n "$NS" debug "node/$n" --image="$IMG" --container="$CNAME" --profile=sysadmin --attach=false -- \
      sh -c "timeout $SECS tcpdump -i any -nn '$FILTER'" >/dev/null 2>&1 || true
  done
  echo ">> waiting $((SECS+60))s (capture + image pulls) ..."
  sleep $((SECS+60))
  for p in $(k -n "$NS" get pods -o name | grep node-debugger); do
    node=$(k -n "$NS" get "$p" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
    echo "===== ${node:-?} ====="
    k -n "$NS" logs "${p#pod/}" -c "$CNAME" 2>/dev/null | grep -E ' IP |packets captured' || echo "(no traffic / OutOfpods)"
  done

elif [ "$MODE" = "pcap" ]; then
  OUT=${OUT:-./presnat-capture}; mkdir -p "$OUT"
  echo ">> per-node pcaps -> $OUT/"
  pids=""
  for n in $NODES; do
    ( k -n "$NS" debug "node/$n" -i --image="$IMG" --container="$CNAME" --profile=sysadmin -- \
        timeout "$SECS" tcpdump -i any -w - "$FILTER" > "$OUT/$n.pcap" 2>/dev/null ) &
    cpid=$!
    ( sleep $((SECS+120)); kill "$cpid" 2>/dev/null ) &   # reaper: frees OutOfpods/stuck attaches
    pids="$pids $cpid"
  done
  # shellcheck disable=SC2086
  wait $pids 2>/dev/null || true
  find "$OUT" -name '*.pcap' -empty -delete 2>/dev/null || true
  if command -v mergecap >/dev/null 2>&1 && ls "$OUT"/*.pcap >/dev/null 2>&1; then
    mergecap -w "$OUT/fleet-presnat.pcap" "$OUT"/*.pcap && echo ">> merged -> $OUT/fleet-presnat.pcap"
  else
    echo ">> per-node pcaps in $OUT/ (install wireshark/mergecap to merge, or open individually)"
  fi
else
  echo "ERROR: unknown mode '$MODE' (use: text | pcap)"; exit 2
fi
