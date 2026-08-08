# syntax=docker/dockerfile:1
#
# Hardened Kubernetes debug image.
# Base: Chainguard Wolfi (minimal, glibc, rebuilt frequently → low/zero CVE).
#
# Base pinned by multi-arch index digest (amd64 + arm64 — keeps native local builds
# and amd64 publish working). Refresh with:
#   docker buildx imagetools inspect --format '{{.Manifest.Digest}}' cgr.dev/chainguard/wolfi-base:latest
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:34977aa13765da89f60fee8fe5230e2bb1c55192df08e383c58221ee0d1277fb

LABEL org.opencontainers.image.title="network-debug-toolbox" \
      org.opencontainers.image.description="Hardened, non-root network debugging toolbox for Kubernetes (Wolfi base)" \
      org.opencontainers.image.source="https://github.com/jC3rny/network-debug-toolbox" \
      org.opencontainers.image.licenses="Apache-2.0"

# Curated network/system debugging toolset — every package verified present in Wolfi.
# Intentionally NOT the netshoot kitchen sink, and NO kubectl (security):
# fewer packages = smaller attack surface.
#   tcpdump          packet capture
#   bind-tools       dig / host (DNS)
#   iproute2         ip, ss
#   iputils          ping
#   netcat-openbsd   nc
#   socat            socket relay
#   conntrack-tools  conntrack (NAT/SNAT translations)
#   iptables         NAT/filter rules (kube-proxy)
#   nftables         nft rules
#   ethtool          NIC info
#   mtr              traceroute + ping
#   iperf3           throughput testing
#   lsof             open files / sockets
#   strace           syscall tracing
#   libcap-utils     getcap / setcap (file capabilities)
#   curl, openssl    HTTP / TLS
#   jq, bash         json / shell
RUN apk add --no-cache \
      bash \
      bind-tools \
      conntrack-tools \
      curl \
      ethtool \
      iperf3 \
      iproute2 \
      iptables \
      iputils \
      jq \
      libcap-utils \
      lsof \
      mtr \
      netcat-openbsd \
      nftables \
      openssl \
      socat \
      strace \
      tcpdump

# Make raw-socket tools usable by a NON-ROOT user via file capabilities.
# Kubernetes has no ambient-capability support, so capabilities added at runtime
# (e.g. --profile=netadmin) are dropped on exec for a non-root user. File caps are
# the portable fix: they activate when the cap is in the container's bounding set
# (i.e. with the netadmin/sysadmin debug profile) — so no root is needed to capture.
RUN setcap cap_net_raw,cap_net_admin+ep "$(command -v tcpdump)" \
 && setcap cap_net_raw+ep "$(command -v ping)"

# Run as non-root by default (uid/gid 65532). Capture works via the file caps above
# plus the netadmin/sysadmin debug profile at runtime — never needs root.
RUN echo 'nonroot:x:65532:65532:nonroot:/home/nonroot:/bin/bash' >> /etc/passwd \
 && echo 'nonroot:x:65532:' >> /etc/group \
 && mkdir -p /home/nonroot \
 && chown 65532:65532 /home/nonroot

USER 65532:65532
WORKDIR /home/nonroot
ENV HOME=/home/nonroot

CMD ["/bin/bash"]
