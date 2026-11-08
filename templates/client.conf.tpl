[Interface]
Address = __CLIENT_ADDRESS__
DNS = 1.1.1.1
PrivateKey = __CLIENT_PRIVATE_KEY__
MTU = __AWG_MTU__
Jc = __JC__
Jmin = __JMIN__
Jmax = __JMAX__
S1 = __S1__
S2 = __S2__
S3 = __S3__
S4 = __S4__
H1 = __H1__
H2 = __H2__
H3 = __H3__
H4 = __H4__

[Peer]
PublicKey = __SERVER_PUBLIC_KEY__
PresharedKey = __SERVER_PSK__
AllowedIPs = __ALLOWED_IPS__
Endpoint = __DOMAIN__:__AWG_PORT__
PersistentKeepalive = 25
