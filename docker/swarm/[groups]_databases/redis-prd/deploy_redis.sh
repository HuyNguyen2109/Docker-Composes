#!/bin/bash
# Define stack name (change this as needed)
STACK_NAME="redis"
REDIS_HAPROXY_CONFIG_FILE="redis-haproxy-config"
# === Remove existing Docker services if it exists ===
docker stack rm "$STACK_NAME" >/dev/null 2>&1 || true
# === Create Docker Config via STDIN ===
echo "Parsing all necessary variables into config..."
docker config rm $REDIS_HAPROXY_CONFIG_FILE
cat <<EOF | docker config create $REDIS_HAPROXY_CONFIG_FILE -
global
    log stdout format raw local0
    daemon
    maxconn 1024

defaults
    log global
    timeout connect 10s
    timeout client 3h
    timeout server 3h
    timeout tunnel 3h
    option tcpka

frontend redis_frontend
    bind *:6379
    default_backend redis_backend

backend redis_backend
    mode tcp
    option tcp-check
    option tcpka
    # Health check simplified: just a PING to avoid misbehavior
    tcp-check connect
    tcp-check send PING\r\n
    tcp-check expect string +PONG

    # Forward only to healthy master
    server redis-master redis-master:6379 check inter 2s fall 3 rise 2
    
    # Slave as backup, not active unless master fails
    server redis-slave-1 redis-slave-1:6379 check inter 2s fall 3 rise 2 backup
    # server redis-slave-2 redis-slave-2:6379 check inter 1s backup
EOF
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
