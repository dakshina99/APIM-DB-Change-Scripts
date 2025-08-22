#!/bin/bash

set -e

COMPOSE_FILE="docker-compose.yml"

echo "Stopping and removing containers, networks, and volumes..."
docker-compose down -v

echo "Docker Compose environment cleaned up successfully."

colima stop 
echo "Colima stopped successfully."