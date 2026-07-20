{
  "_comment": "参考模板；实际由 lib/config.sh 按本机双栈自适应生成（dual=0.0.0.0+::）",
  "log": {
    "level": "debug",
    "timestamp": true,
    "output": "/var/log/geoproxy-server/sing-box.log"
  },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in-v4",
      "listen": "0.0.0.0",
      "listen_port": 443,
      "users": [{ "uuid": "UUID", "password": "PASSWORD" }],
      "congestion_control": "bbr",
      "zero_rtt_handshake": true,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/geoproxy-server/tls/cert.pem",
        "key_path": "/etc/geoproxy-server/tls/key.pem",
        "alpn": ["h3"]
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in-v6",
      "listen": "::",
      "listen_port": 443,
      "users": [{ "uuid": "UUID", "password": "PASSWORD" }],
      "congestion_control": "bbr",
      "zero_rtt_handshake": true,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/geoproxy-server/tls/cert.pem",
        "key_path": "/etc/geoproxy-server/tls/key.pem",
        "alpn": ["h3"]
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
