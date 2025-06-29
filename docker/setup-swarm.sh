#!/bin/bash

set -e

APP_DIR="/home/ansible/myapp/docker"
BRIDGE_NET="swarm-bridge"
OVERLAY_NET="swarm-net"
MANAGER_IP="192.168.99.100"
IMAGE_NAME="myphpapp:latest"

declare -A NODE_IPS
NODE_IPS=( ["manager"]="192.168.99.100" ["worker1"]="192.168.99.101" ["worker2"]="192.168.99.102" )

echo "[0/13] Cleaning up containers, networks, images..."
docker rm -f manager worker1 worker2 &>/dev/null || true
docker network rm $BRIDGE_NET &>/dev/null || true
docker network rm $OVERLAY_NET &>/dev/null || true
docker rmi -f $IMAGE_NAME &>/dev/null || true
docker volume prune -f --filter "label!=important" &>/dev/null || true

echo "[1/13] Installing Docker if needed..."
if ! command -v docker &>/dev/null; then
  apt-get update
  apt-get install -y docker.io
  systemctl enable docker
  systemctl start docker
fi

echo "[2/13] Creating bridge network: $BRIDGE_NET..."
docker network create \
  --driver=bridge \
  --subnet=192.168.99.0/24 \
  --gateway=192.168.99.1 \
  $BRIDGE_NET 2>/dev/null || echo "Bridge exists."

echo "[3/13] Launching DIND containers..."
for NODE in manager worker1 worker2; do
  docker run -dit --privileged --name $NODE --hostname $NODE \
    --network $BRIDGE_NET \
    --ip ${NODE_IPS[$NODE]} \
    docker:dind
done

echo "[4/13] Waiting for Docker to initialize..."
sleep 6

echo "[5/13] Initializing Docker Swarm..."
docker exec -it manager docker swarm init --advertise-addr $MANAGER_IP || true
JOIN_TOKEN=$(docker exec -it manager docker swarm join-token -q worker | tr -d '\r')
JOIN_CMD="docker swarm join --token $JOIN_TOKEN $MANAGER_IP:2377"

echo "[6/13] Joining workers to the Swarm..."
for NODE in worker1 worker2; do
  docker exec -it $NODE $JOIN_CMD || echo "$NODE already joined."
done

echo "[7/13] Replacing manager with volume + port 8080 exposed..."
docker stop manager && docker rm manager

docker run -dit --privileged --name manager \
  --hostname manager \
  --network $BRIDGE_NET \
  --ip $MANAGER_IP \
  -p 8080:8080 \
  -v "$APP_DIR":/app \
  docker:dind

echo "[8/13] Waiting for manager's Docker to restart..."
sleep 6

echo "[9/13] Building PHP image from ./www..."
docker build -t $IMAGE_NAME "$APP_DIR/www"

echo "[10/13] Loading image into manager container..."
docker save $IMAGE_NAME | docker exec -i manager docker load

echo "[11/13] Deploying stack to Swarm..."
docker exec -i manager sh -c "
  docker swarm init --advertise-addr $MANAGER_IP || true
  docker network create --driver overlay $OVERLAY_NET || true
  cd /app
  docker stack deploy -c docker-compose.yml myapp
"

echo ""
echo "[11.5/13] Waiting briefly for services to initialize 10sec..."
sleep 10

echo ""
echo "[12/13] Verifying Swarm status..."

echo ""
echo "Swarm Nodes:"
docker exec -it manager docker node ls

echo ""
echo "Services:"
docker exec -it manager docker service ls

echo ""
echo "🧱 Web Service Tasks:"
docker exec -it manager docker service ps myapp_web

echo ""
echo "Docker-in-Docker Node IPs (swarm-bridge):"
for NODE in manager worker1 worker2; do
  IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $NODE)
  echo "  $NODE → $IP"
done

echo ""
echo "Container IPs (swarm-net):"
docker exec -i manager sh -c '
  echo "- Web Containers:"
  for cid in $(docker ps -q --filter name=myapp_web); do
    echo "  Container: $cid"
    docker inspect --format="    {{.Name}} - {{with index .NetworkSettings.Networks \"swarm-net\"}}{{.IPAddress}}{{end}}" $cid
  done

  echo "- DB Container:"
  cid=$(docker ps -q --filter name=myapp_db)
  if [ -n "$cid" ]; then
    docker inspect --format="    {{.Name}} - {{with index .NetworkSettings.Networks \"swarm-net\"}}{{.IPAddress}}{{end}}" $cid
  else
    echo "    ⚠️ DB container not running."
    docker service ps myapp_db
    docker service logs myapp_db
  fi
'

echo ""
echo "Networks:"
docker exec -it manager docker network ls

echo ""
echo "[13/13] Web app is deployed and running."
echo "You can now test the app in your terminal using:"
echo ""
echo "   lynx http://localhost:8080"
echo ""
echo "🎉 Setup complete!"
