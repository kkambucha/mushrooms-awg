services:
  amneziawg:
    # Pinned: AmneziaWG userspace + tools verified for AWG 2.x-compatible client .conf
    image: amneziavpn/amneziawg-go:3.1.20260828
    platform: linux/amd64
    container_name: mushrooms_awg
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./awg:/opt/amnezia/awg
      - ./start.sh:/opt/amnezia/start.sh:ro
    entrypoint: ["/bin/bash", "/opt/amnezia/start.sh"]
