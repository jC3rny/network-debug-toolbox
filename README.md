# network-debug-toolbox

Hardened, non-root network debugging toolbox for Kubernetes — a low-CVE, Wolfi-based
alternative to `nicolaka/netshoot`.

Pull it into a running pod or node with `kubectl debug` and you get the usual network
diagnostics (`tcpdump`, `conntrack`, `iproute2`, `mtr`, …) — but from a minimal, regularly
rebuilt base, running as a non-root user, and still able to capture packets thanks to file
capabilities.

## Why

- **Secure base:** Chainguard **Wolfi** (`cgr.dev/chainguard/wolfi-base`) — minimal, glibc,
  rebuilt frequently, typically low/zero CVE. Not Alpine, not the netshoot kitchen sink.
- **Curated toolset:** only what network/system debugging needs (fewer packages = smaller
  attack surface): `tcpdump bind-tools iproute2 iputils netcat-openbsd socat conntrack-tools
  iptables nftables ethtool mtr iperf3 lsof strace curl openssl jq bash`. No `kubectl`
  (you run it from your workstation; bundling it + a mounted SA token is a lateral-movement
  risk).
- **Non-root by default** (uid 65532). `tcpdump`/`ping` carry **file capabilities**, so
  capture works as non-root with the `--profile=netadmin` (pods) / `--profile=sysadmin`
  (nodes) debug profile — never root. (Kubernetes has no ambient caps, so file caps are
  required.)
- **Scanned with Trivy** on every build (image vulns + Dockerfile misconfig); fails on
  HIGH/CRITICAL. A CycloneDX SBOM is generated and attached to the published image.

## Use with `kubectl debug`

```bash
IMG=<registry>/<user>/network-debug-toolbox:latest

# inside a pod (packet capture needs the netadmin profile)
kubectl debug -it <pod> -n <ns> --image=$IMG --target=<container> --profile=netadmin -- bash
# then, inside: tcpdump -i any -nn 'port 8080'

# on a node / host netns (e.g. to see pre-SNAT client IPs before kube-proxy rewrites them)
kubectl debug node/<node> -it --image=$IMG --profile=sysadmin -- \
  tcpdump -i any -nn 'tcp port <nodePort>'

# save a pcap for Wireshark (no -t — a TTY corrupts the binary stream)
kubectl debug -i <pod> -n <ns> --image=$IMG --target=<container> --profile=netadmin -- \
  tcpdump -i any -w - 'port 8080' > pod.pcap
```

> **Non-root note:** capture works non-root because the binaries carry file capabilities and
> you pass `--profile=netadmin/sysadmin`. Deep host **filesystem** access during node debug
> may still need a root override; non-root + caps covers *network* capture.

### Verify capture works (inside the debug container)

```bash
id                                  # uid=65532 (non-root)
getcap "$(command -v tcpdump)"      # → cap_net_admin,cap_net_raw=ep
tcpdump -D                          # lists interfaces (no permission error)
```

## Build & scan locally

```bash
make            # build + scan Dockerfile config + scan image (fails on HIGH/CRITICAL)
make verify     # full vulnerability report (all severities, never fails)
make verify-caps# assert tcpdump keeps its file caps (non-root capture guard)
make sbom       # CycloneDX SBOM
```

Trivy runs via Docker (no local install needed). Local builds are **native** (e.g. arm64 on
Apple Silicon) for speed.

## Publish

CI (GitHub Actions, `.github/workflows/docker-publish.yml`) builds multi-arch
(`linux/amd64,linux/arm64`), runs the Trivy + file-caps gate, and pushes to Docker Hub on
pushes to `main` and on `v*` tags. Configure these under **Settings → Secrets and
variables → Actions**:

| Name | Kind | Purpose |
|---|---|---|
| `DOCKERHUB_USERNAME` | **Variable** | Docker Hub account the image is pushed under (not sensitive — kept a variable so it stays readable in logs) |
| `DOCKERHUB_TOKEN` | **Secret** | Docker Hub access token (Account Settings → Security) |

To publish manually instead:

```bash
docker login
make publish IMAGE=<user>/network-debug-toolbox TAG=$(date +"%Y%m%d")
```

`make publish` forces `linux/amd64`, runs the full scan + verify-caps gate, pushes, then
attaches the CycloneDX SBOM to the pushed image as an OCI referrer (needs `oras` —
`brew install oras`). Pin the Wolfi base to a digest before production use (the Dockerfile
already pins one; refresh it with the command in the Dockerfile header).

## `scripts/presnat-capture.sh`

Helper to capture **pre-SNAT** traffic (real client IPs) for a `LoadBalancer`/`NodePort`
Service across nodes — it discovers the VIP, service ports and nodePorts, builds the BPF
filter, runs `kubectl debug node/...` on each node with this image, and (in `pcap` mode)
merges the per-node captures. See `./presnat-capture.sh -h`.

## License

Apache-2.0 — see [LICENSE](./LICENSE).
