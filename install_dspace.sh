#!/bin/bash

# DSpace Installation Script for Ubuntu 24.04
# Author: OtCloud Company Limited | www.otcloud.co.ke
# Date: 26-01-2025

# Exit on error
set -e

# Define variables
POSTGRES_USER="dspace"
POSTGRES_PASSWORD="dspace"
POSTGRES_DB="dspace"
DS_VERSION="8.0"  # Change to the version you want
DS_DIR="/opt/dspace-8"
TOMCAT_VERSION="10"
TOMCAT_USER="tomcat"
TOMCAT_HOME="/opt/tomcat"
SOLR_PORT="8983"
SOLR_VERSION="8.11.4"
SERVER_HOSTNAME="dspace.otcloud.co.ke"
SERVER_URL=http://$SERVER_HOSTNAME
STARTED_AT=$(date)

echo "Starting DSpace '$DS_VERSION' installation"

# Update and upgrade system
echo "Updating the system..."
sudo apt update && sudo apt upgrade -y

# Install Java (OpenJDK 11 or later is recommended)
echo "Installing dspace '$DS_VERSION'dependencies..."
sudo apt install openjdk-17-jdk git ant ant-optional maven postgresql postgresql-contrib libpostgresql-jdbc-java zip npm nginx -y

# Configure PostgreSQL
echo "Configuring PostgreSQL..."
sudo -i -u postgres psql -c "CREATE USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';"
sudo -i -u postgres psql -c "CREATE DATABASE $POSTGRES_DB WITH OWNER $POSTGRES_USER ENCODING 'UTF8' LC_COLLATE='en_US.UTF-8' LC_CTYPE='en_US.UTF-8' TEMPLATE=template0;"
sudo -i -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" -d $POSTGRES_DB

# Install Node.js and Yarn
echo "Installing Node.js and Yarn..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
npm install -g yarn

# Install Apache Solr
echo "Installing Apache Solr..."
wget https://dlcdn.apache.org/lucene/solr/$SOLR_VERSION/solr-$SOLR_VERSION.tgz
tar xzf solr-$SOLR_VERSION.tgz
sudo bash solr-$SOLR_VERSION/bin/install_solr_service.sh solr-$SOLR_VERSION.tgz 
rm -rf solr-$SOLR_VERSION solr-$SOLR_VERSION.tgz

# Download and Build DSpace Backend
echo "Downloading and building DSpace $DS_VERSION backend..."
wget https://github.com/DSpace/DSpace/archive/refs/tags/dspace-$DS_VERSION.tar.gz

tar -xvzf dspace-$DS_VERSION.tar.gz
cd DSpace-dspace-$DS_VERSION

mvn package

echo "Creating deployment directories ..."
sudo mkdir -p $DS_DIR/server
sudo mkdir -p $DS_DIR/client
sudo chown $USER:$USER $DS_DIR

# Create local.cfg 
echo "Create local.cfg"
cp dspace/config/dspace.cfg dspace/target/dspace-installer/config/local.cfg

# Update local.cfg settings
echo "Updating local.cfg ..."
sed -i "s|dspace.dir = /dspace|dspace.dir = $DS_DIR/server|g" dspace/target/dspace-installer/config/local.cfg
sed -i "s|db.username = dspace|db.username = $POSTGRES_USER|g" dspace/target/dspace-installer/config/local.cfg
sed -i "s|db.password = dspace|db.password = $POSTGRES_PASSWORD|g" dspace/target/dspace-installer/config/local.cfg
sed -i "s|dspace.server.url = http://localhost:8080/server|dspace.server.url = $SERVER_URL/server|g" dspace/target/dspace-installer/config/local.cfg
sed -i "s|dspace.ui.url = http://localhost:4000|dspace.server.url = $SERVER_URL|g" dspace/target/dspace-installer/config/local.cfg

# Install DSpace
echo "Deploying DSpace to '$DS_DIR'"
cd dspace/target/dspace-installer
ant fresh_install
cd $DS_DIR/server

# Copy solr cores
echo "Creating solr cores ... "
sudo cp -r solr/* /var/solr/data/
sudo chown solr:solr -R /var/solr/data

echo "Restarting solr ..."
sudo systemctl restart solr

echo "Initializing the db ..."
sudo bin/dspace database migrate

echo "Creating dspace.service file ..."
sudo tee /etc/systemd/system/dspace.service > /dev/null <<EOL
[Unit]
Description=DSpace $DS_VERSION Backend
After=network.target

[Service]
ExecStart=/usr/bin/java -jar $DS_DIR/server/webapps/server-boot.jar
WorkingDirectory=$DS_DIR/server/webapps/
Restart=on-failure
Environment=JAVA_OPTS="-Xms512m -Xmx2048m"
Environment=DS_HOME=$DS_DIR/server

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable the DSpace service
echo "Enabling and starting the DSpace service..."
sudo systemctl daemon-reload
sudo systemctl enable dspace.service
sudo systemctl start dspace.service

echo "Dspace $DS_VERSION backend is now installed ... !"

# Go back home
cd ~

echo "Cleaning up backend source code ... "
sudo rm -rf DSpace-dspace-$DS_VERSION
sudo rm -rf dspace-$DS_VERSION.tar.gz

# Set up DSpace frontend
echo "Setting up DSpace $DS_VERSION Angular frontend ..."
echo "Downloading the front end source code ..."
wget -c https://github.com/DSpace/dspace-angular/archive/refs/tags/dspace-$DS_VERSION.tar.gz

echo "Extracting the achive"
tar -zxvf dspace-$DS_VERSION.tar.gz && cd dspace-angular-dspace-$DS_VERSION

echo "Installing yarn and pm2"
sudo npm install -g yarn pm2

echo "Installing dspace $DS_VERSION front-end dependencies"
yarn install

echo "Building the app for production"
yarn build:prod

echo "Copying the app to the deployment folder"
cp -r dist $DS_DIR/client/

echo "Creating config directory"
mkdir -p $DS_DIR/client/config

echo "Creating config.prod.yml"
cp config/config.example.yml $DS_DIR/client/config/config.prod.yml

echo "Updating the front-end configuration file config.prod.yml"
sed -i "s|port: 443|port: 80|g" $DS_DIR/client/config/config.prod.yml
sed -i "s|ssl: true|ssl: false|g" $DS_DIR/client/config/config.prod.yml
sed -i "s|host: sandbox.dspace.org|host: $SERVER_HOSTNAME|g" $DS_DIR/client/config/config.prod.yml

echo "Switching to $DS_DIR/client"
cd $DS_DIR/client

echo "Creating pm2 config file dspace-ui.json"
# Adjust the number of instances depending on your server resources
sudo tee ./dspace-ui.json > /dev/null <<EOL
{
    "apps": [
        {
           "name": "dspace-ui",
           "cwd": "$DS_DIR/client",
           "script": "dist/server/main.js",
           "instances": 4,
           "exec_mode": "cluster",
           "env": {
              "NODE_ENV": "production"
           }
        }
    ]
}
EOL

echo "Starting the front end app with pm2"
pm2 start dspace-ui.json

echo "Configuring nginx"
# Create Nginx site configuration for DSpace
echo "Creating Nginx site configuration for DSpace..."
sudo tee /etc/nginx/sites-available/$SERVER_HOSTNAME > /dev/null <<EOL
server {
  listen 80;

  server_name    $SERVER_HOSTNAME;
  access_log /var/log/nginx/dspace-access.log;
  error_log /var/log/nginx/dspace-error.log;

  location /server {
    # proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host \$server_name;
    proxy_pass http://localhost:8080/server;
  }

  location / {
        proxy_set_header X-Forwarded-Host \$server_name;
        proxy_set_header X-Forwarded-Server \$server_name;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://localhost:4000/;
  }
}
EOL

# Enable the Nginx site configuration
echo "Enabling Nginx configuration..."
sudo ln -s /etc/nginx/sites-available/$SERVER_HOSTNAME /etc/nginx/sites-enabled/$SERVER_HOSTNAME

# Test Nginx configuration
echo "Testing Nginx configuration ... "
sudo nginx -t

# Restart Nginx to apply changes
echo "Restarting Nginx..."
sudo systemctl restart nginx

FINISHEDED_AT=$(date)
echo "DSpace 8 installation completed successfully!"
echo "Backend: $SERVER_URL/server"
echo "Frontend: $SERVER_URL"
echo "Started at $STARTED_AT"
echo "Finished at $FINISHEDED_AT"

