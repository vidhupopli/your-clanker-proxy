# Fallback image — unused by default.
# Production uses docker-compose.yml, which pins ghcr.io/tarampampam/3proxy by linux/arm64 digest.
# Build only if GHCR is unreachable: docker build -t connect-proxy:local .

FROM alpine:3.21 AS build

ARG THE3PROXY_VERSION=0.9.7

RUN apk add --no-cache gcc make musl-dev linux-headers wget tar \
 && wget -qO- "https://github.com/3proxy/3proxy/archive/refs/tags/${THE3PROXY_VERSION}.tar.gz" \
 | tar -xz \
 && make -C "3proxy-${THE3PROXY_VERSION}" -f Makefile.Linux \
 && install -m 0755 "3proxy-${THE3PROXY_VERSION}/bin/3proxy" /usr/local/bin/3proxy

FROM alpine:3.21

COPY --from=build /usr/local/bin/3proxy /usr/local/bin/3proxy
RUN adduser -D -H -u 10001 proxy \
 && mkdir -p /etc/3proxy \
 && chown 10001:10001 /etc/3proxy

EXPOSE 443
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/3proxy"]
CMD ["/etc/3proxy/3proxy.cfg"]
