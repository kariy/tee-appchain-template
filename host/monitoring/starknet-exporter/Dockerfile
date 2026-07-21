# Tiny exporter: plain-python JSON-RPC `starknet_call` for STRK balanceOf, serving
# /metrics. Sibling of succinct-exporter.
FROM alpine:3.20
RUN apk add --no-cache python3 ca-certificates
COPY exporter.py /exporter.py
ENTRYPOINT ["python3", "/exporter.py"]
