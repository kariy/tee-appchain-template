# Tiny exporter: grpcurl (to call the Succinct ProverNetwork GetBalance gRPC) + python (to
# serve /metrics). x86_64 host.
FROM alpine:3.20
ARG GRPCURL_VERSION=1.9.1
RUN apk add --no-cache python3 curl ca-certificates \
 && curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz" \
    | tar xz -C /usr/local/bin grpcurl \
 && chmod +x /usr/local/bin/grpcurl
COPY proto /proto
COPY exporter.py /exporter.py
ENTRYPOINT ["python3", "/exporter.py"]
