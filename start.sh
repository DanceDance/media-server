#!/bin/bash

# Ensure .env exists before starting
if [ ! -f .env ]; then
  echo "Initializing .env from .env.defaults..."
  cp .env.defaults .env
  echo "✅ Created .env file. Please review and modify it if necessary before continuing."
  # Optionally you might want to stop here to let them edit it, 
  # but proceeding is also fine if defaults work out of the box.
fi

/usr/bin/docker compose pull
/usr/bin/docker compose up -d
/usr/bin/docker image prune -f
