# Pinned by digest, never a floating tag — this container holds a read-only
# mount of the host root filesystem.
FROM alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

RUN apk add --no-cache curl jq

COPY canary.sh /usr/local/bin/canary.sh
RUN chmod +x /usr/local/bin/canary.sh

USER nobody

ENTRYPOINT ["/usr/local/bin/canary.sh"]
