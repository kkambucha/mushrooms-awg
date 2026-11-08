# Mushrooms-AWG runtime: isgulkov amneziawg-go (TCP/network UAPI) + official awg tools + socat
# Pin: commit with network/format_in/format_out UAPI (TCP e2e).
ARG AWG_GO_REF=a8711790df56d00dc9f65960c480a0ea901b2fc0
ARG OFFICIAL_IMAGE=amneziavpn/amneziawg-go:3.1.20260828

FROM golang:1.24-alpine AS build-go
ARG AWG_GO_REF
RUN apk add --no-cache git make gcc musl-dev linux-headers bash
WORKDIR /src
RUN git clone --filter=blob:none https://github.com/isgulkov/amneziawg-go.git . \
  && git checkout "${AWG_GO_REF}"
RUN go build -v -o /out/amneziawg-go .

FROM ${OFFICIAL_IMAGE} AS official

FROM alpine:3.20
RUN apk add --no-cache \
      bash \
      iptables \
      iproute2 \
      socat \
      openresolv \
      libqrencode-tools \
    && mkdir -p /var/run/amneziawg
# Userspace daemon with TCP UAPI
COPY --from=build-go /out/amneziawg-go /usr/bin/amneziawg-go
# Conf tools (Jc/H/S setconf) from official image; Network stays via UAPI in start.sh
COPY --from=official /usr/bin/awg /usr/bin/awg
COPY --from=official /usr/bin/awg-quick /usr/bin/awg-quick
RUN chmod 755 /usr/bin/amneziawg-go /usr/bin/awg /usr/bin/awg-quick
WORKDIR /opt/amnezia
CMD ["/bin/bash"]
