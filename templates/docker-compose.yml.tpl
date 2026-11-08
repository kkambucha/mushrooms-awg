services:
  amneziawg:
    # Built locally: isgulkov amneziawg-go (TCP UAPI) + official awg tools. See docker/Dockerfile.
    image: __AWG_RUNTIME_IMAGE__
    build:
      context: __DOCKER_BUILD_CONTEXT__
      dockerfile: Dockerfile
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
