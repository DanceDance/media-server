#!/bin/bash

# Get the absolute path of the current directory
PROJECT_DIR=$(pwd)
SCRIPT_PATH="$PROJECT_DIR/update_stack.sh"
JOB="0 4 * * 1 /bin/bash $SCRIPT_PATH >> $PROJECT_DIR/update.log 2>&1"

# 1. Create the actual update script if it doesn't exist
cat <<EOF > update_stack.sh
#!/bin/bash
cd $PROJECT_DIR
/usr/bin/docker compose pull
/usr/bin/docker compose up -d
/usr/bin/docker image prune -f
EOF

chmod +x update_stack.sh

# 2. Add to crontab if not already present
(crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH") || (crontab -l 2>/dev/null; echo "$JOB") | crontab -

echo "✅ Cron job scheduled: Every Monday at 4:00 AM"
echo "✅ Update script created at: $SCRIPT_PATH"
