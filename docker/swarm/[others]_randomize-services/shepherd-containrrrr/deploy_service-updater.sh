#!/bin/bash
# Load environment variables from .env file
if [ -f .env ]; then
    set -a  # Automatically export all variables
    source .env
    set +a
else
    echo "⚠️  .env file not found! Make sure it exists in the current directory."
    exit 1
fi
# Define stack name (change this as needed)
STACK_NAME="service-updater"
# Deploy the stack
docker stack deploy -c docker-compose.yml "$STACK_NAME"
echo "✅ Docker stack '$STACK_NAME' deployed successfully!"
