#!/bin/bash

# Function to log messages with timestamps
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if PostgreSQL role exists
role_exists() {
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$1'" | grep -q 1
}

# Function to check if database exists
database_exists() {
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$1'" | grep -q 1
}

# Exit on any error
set -e

log_message "Starting deployment process..."

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    log_message "Error: Please do not run this script as root"
    exit 1
fi

# Update package list
log_message "Updating package list..."
sudo apt-get update

# Install prerequisites
log_message "Installing prerequisites..."
sudo apt-get install -y curl gnupg2 build-essential nginx

# Install Node.js 20.x if not already installed
if ! command_exists node; then
    log_message "Installing Node.js 20.x..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
    sudo apt-get install -y nodejs
else
    log_message "Node.js is already installed: $(node --version)"
fi

# Install PostgreSQL if not already installed
if ! command_exists psql; then
    log_message "Installing PostgreSQL..."
    sudo apt-get install -y postgresql postgresql-contrib
else
    log_message "PostgreSQL is already installed: $(psql --version)"
fi

# Ensure PostgreSQL service is running
log_message "Ensuring PostgreSQL service is running..."
if ! sudo systemctl is-active --quiet postgresql; then
    sudo systemctl start postgresql
fi
sudo systemctl enable postgresql

# Setup PostgreSQL user and database
log_message "Setting up PostgreSQL database..."
if ! role_exists "achievementapp"; then
    sudo -u postgres psql -c "CREATE USER achievementapp WITH PASSWORD 'achievement123';"
    log_message "Created PostgreSQL user 'achievementapp'"
else
    log_message "PostgreSQL user 'achievementapp' already exists"
fi

if ! database_exists "achievements"; then
    sudo -u postgres psql -c "CREATE DATABASE achievements OWNER achievementapp;"
    log_message "Created database 'achievements'"
else
    log_message "Database 'achievements' already exists"
fi

sudo -u postgres psql -c "ALTER USER achievementapp WITH SUPERUSER;"

# Change to the correct application directory
log_message "Changing to application directory..."
cd /home/joel_kaufmann/achievement-tracker

# Install dependencies
log_message "Installing project dependencies..."
npm install

# Create or update environment file
log_message "Setting up environment file..."
cat > .env << EOL
DATABASE_URL=postgresql://achievementapp:achievement123@localhost:5432/achievements
PORT=5000
NODE_ENV=production
EOL

# Verify environment file was created and has correct permissions
if [ ! -f .env ]; then
    log_message "Error: Failed to create .env file"
    exit 1
fi

# Verify DATABASE_URL is accessible
if ! grep -q "DATABASE_URL" .env; then
    log_message "Error: DATABASE_URL not found in .env file"
    exit 1
fi

# Set correct permissions
chmod 600 .env
log_message "Environment file created and secured"

# Run database migrations
log_message "Running database migrations..."
npm run db:push

# Install PM2 if not already installed
if ! command_exists pm2; then
    log_message "Installing PM2..."
    sudo npm install -g pm2
else
    log_message "PM2 is already installed: $(pm2 --version)"
fi

# Build the application
log_message "Building the application..."
npm run build

# Stop existing PM2 process if it exists (ignore errors if it doesn't)
log_message "Setting up PM2 process..."
pm2 delete achievement-tracker 2>/dev/null || true

# Start PM2 with environment variables
log_message "Starting new PM2 process..."
DATABASE_URL="postgresql://achievementapp:achievement123@localhost:5432/achievements" \
PORT=5000 \
NODE_ENV=production \
pm2 start npm --name "achievement-tracker" --update-env -- start

# Save PM2 process list and configure to start on reboot
log_message "Configuring PM2 startup..."
pm2 save
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u $USER --hp $HOME

# Setup Nginx
log_message "Configuring Nginx..."
sudo tee /etc/nginx/sites-available/achievement-tracker << 'EOL'
server {
    listen 443 default_server;
    server_name _;

    client_max_body_size 50M;

    location / {
        proxy_pass http://localhost:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    error_page 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOL

# Enable the Nginx configuration
log_message "Enabling Nginx configuration..."
sudo ln -sf /etc/nginx/sites-available/achievement-tracker /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test Nginx configuration
log_message "Testing Nginx configuration..."
sudo nginx -t

# Restart Nginx
log_message "Restarting Nginx..."
sudo systemctl restart nginx

# Open firewall port if UFW is active
if command_exists ufw; then
    log_message "Configuring firewall..."
    sudo ufw allow 443
fi

# Verify port availability
log_message "Verifying port 443..."
sleep 5  # Give the application time to start
if netstat -tulpn 2>/dev/null | grep -q ":443 "; then
    log_message "Application is running on port 443"
else
    log_message "Warning: No process found listening on port 443"
    log_message "Checking nginx status..."
    sudo systemctl status nginx
fi

log_message "Deployment complete!"
log_message "Your application should now be running on http://your-ip:443"

# Add monitoring instructions
cat << "EOL"

Monitoring Instructions:
----------------------
- View PM2 logs: pm2 logs
- Monitor PM2 processes: pm2 monit
- View PM2 status: pm2 status
- View Nginx logs: sudo tail -f /var/log/nginx/error.log
- View Nginx access logs: sudo tail -f /var/log/nginx/access.log

Troubleshooting:
---------------
1. Check application logs: pm2 logs achievement-tracker
2. Check Nginx logs: sudo journalctl -u nginx
3. Check PostgreSQL logs: sudo journalctl -u postgresql
4. Verify database connection: psql -U achievementapp -d achievements -h localhost
5. Check port status: sudo netstat -tulpn | grep 443

EO
