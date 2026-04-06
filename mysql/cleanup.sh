#!/bin/bash

set -e

# Detect docker compose command
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    echo "[ERROR] Neither 'docker compose' plugin nor 'docker-compose' standalone is available."
    exit 1
fi

echo "Stopping and removing containers, networks, and volumes..."
$DOCKER_COMPOSE_CMD down -v

echo "Docker Compose environment cleaned up successfully."