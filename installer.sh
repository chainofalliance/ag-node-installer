#!/bin/bash

# Enable error handling - exit on error
set -e

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Create a file descriptor for logging (3)
exec 3>&1

# Redirect all output to /dev/null except our logging
exec 1>/dev/null 2>&1

# Logging functions for consistent output
log_info() {
  echo -e "${YELLOW}[INFO]${NC} $1" >&3
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1" >&3
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1" >&3
}

# Function to handle errors
handle_error() {
  local exit_code=$1
  local error_message=$2
  echo -e "${RED}[ERROR]${NC} $error_message" >&3
  echo -e "${RED}[ERROR]${NC} Installation failed. Exiting..." >&3
  exit $exit_code
}

# Check if user has sudo privileges
check_sudo() {
  log_info "Checking sudo privileges..."
  if sudo -n true; then
    log_success "Sudo privileges confirmed."
  else
    handle_error 1 "This script requires sudo privileges to install and configure software.
Please run this script with a user that has sudo privileges or run 'sudo -v' first."
  fi
}

# Function to determine OS type
determine_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$ID"
    
    case "$OS_NAME" in
      ubuntu|debian)
        log_info "Operating System: $PRETTY_NAME"
        ;;
      *)
        handle_error 1 "Unsupported operating system. Only Ubuntu and Debian are supported."
        ;;
    esac
  else
    handle_error 1 "Cannot determine operating system."
  fi
}

# Function to check if a package is installed
package_installed() {
  if command -v "$1"; then
    return 0  # Package is installed
  else
    return 1  # Package is not installed
  fi
}

# Function to check if a service is installed
service_installed() {
  if systemctl list-unit-files | grep -q "$1.service"; then
    return 0  # Service is installed
  else
    return 1  # Service is not installed
  fi
}

# Function to install required packages
install_dependencies() {
  log_info "Installing required dependencies..."
  
  case "$OS_NAME" in
    ubuntu|debian)
      if ! sudo apt-get update -y; then
        handle_error 1 "Failed to update package lists."
      fi
      
      if ! sudo apt-get install -y curl wget dnsutils net-tools; then
        handle_error 1 "Failed to install required dependencies."
      fi
      ;;
  esac
  
  # Verify essential tools are installed
  for cmd in curl wget dig; do
    if ! command -v $cmd; then
      handle_error 1 "Required tool '$cmd' is not installed despite installation attempt."
    fi
  done
  
  log_success "Dependencies installed successfully."
}

# Function to get the current server's IP addresses
get_server_ips() {
  # Get all IPv4 addresses
  local ip_addresses=$(hostname -I)
  if [ -z "$ip_addresses" ]; then
    log_warning "Could not determine local IP addresses."
  fi
  echo "$ip_addresses"
  
  # Get public IP if available
  local public_ip=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
  if [ -n "$public_ip" ]; then
    echo "$public_ip"
  else
    log_warning "Could not determine public IP address."
  fi
}

# Function to validate URL
validate_url() {
  local url="$1"
  
  # Check if URL starts with https://
  if [[ ! "$url" =~ ^https:// ]]; then
    log_warning "URL must start with https://"
    return 1
  fi
  
  # Extract domain from URL
  local domain=$(echo "$url" | sed -E 's|https://([^:/]+).*|\1|')
  
  log_info "Validating that $domain resolves to this server..."
  
  # Get IP addresses of the domain
  local domain_ips=$(dig +short "$domain" || host "$domain" | grep "has address" | cut -d " " -f 4)
  
  if [ -z "$domain_ips" ]; then
    log_warning "Could not resolve domain $domain"
    return 1
  fi
  
  # Get server's IP addresses
  local server_ips=$(get_server_ips)
  if [ -z "$server_ips" ]; then
    log_warning "Could not determine server IP addresses"
    return 1
  fi
  
  # Check if any of the domain's IPs match any of the server's IPs
  local found=0
  for domain_ip in $domain_ips; do
    if echo "$server_ips" | grep -qw "$domain_ip"; then
      log_success "Verified: $domain ($domain_ip) resolves to this server"
      found=1
      break
    fi
  done
  
  if [ "$found" -eq 0 ]; then
    log_warning "URL does not resolve to this server. Domain resolves to: $domain_ips"
    log_info "This server's IPs: $server_ips"
    return 1
  fi
  
  return 0
}

# Function to prompt for node URL
prompt_node_url() {
  local valid=0
  local node_url=""
  
  while [ "$valid" -eq 0 ]; do
    echo -e "${YELLOW}[INFO]${NC} Enter your node URL (must use https and resolve to this server): " >&3
    read node_url >&3
    
    if validate_url "$node_url"; then
      valid=1
      log_success "Node URL validated successfully: $node_url"
      NODE_URL="$node_url"
    else
      log_warning "Invalid URL. Please try again."
    fi
  done
}

# Function to detect if Apache or Nginx is installed
detect_web_server() {
  if package_installed "nginx" || service_installed "nginx"; then
    WEB_SERVER="nginx"
    log_info "Detected web server: Nginx"
    return 0
  elif package_installed "apache2" || service_installed "apache2"; then
    WEB_SERVER="apache"
    log_info "Detected web server: Apache"
    return 0
  else
    log_info "No web server (Apache or Nginx) detected."
    return 1
  fi
}

# Function to install and configure Apache
install_apache() {
  log_info "Installing Apache web server..."
  
  case "$OS_NAME" in
    ubuntu|debian)
      if ! sudo apt-get update -y; then
        handle_error 1 "Failed to update package lists."
      fi
      
      if ! sudo apt-get install -y apache2; then
        handle_error 1 "Failed to install Apache web server."
      fi
      
      # Enable required modules
      log_info "Enabling required Apache modules..."
      modules=("ssl" "proxy" "proxy_http" "headers" "proxy_wstunnel" "rewrite")
      for module in "${modules[@]}"; do
        if ! sudo a2enmod $module; then
          handle_error 1 "Failed to enable Apache module: $module"
        fi
      done
      
      # Restart Apache to apply changes
      log_info "Restarting Apache to apply module changes..."
      if ! sudo systemctl restart apache2; then
        handle_error 1 "Failed to restart Apache after enabling modules."
      fi
      ;;
  esac
  
  # Verify installation
  if service_installed "apache2"; then
    log_success "Apache has been successfully installed."
    WEB_SERVER="apache"
    return 0
  else
    handle_error 1 "Apache installation verification failed."
  fi
}

# Function to install and configure Nginx
install_nginx() {
  log_info "Installing Nginx web server..."
  
  case "$OS_NAME" in
    ubuntu|debian)
      if ! sudo apt-get update -y; then
        handle_error 1 "Failed to update package lists."
      fi
      
      if ! sudo apt-get install -y nginx; then
        handle_error 1 "Failed to install Nginx web server."
      fi
      
      # Ensure Nginx is started and enabled
      log_info "Starting and enabling Nginx service..."
      if ! sudo systemctl start nginx; then
        handle_error 1 "Failed to start Nginx service."
      fi
      
      if ! sudo systemctl enable nginx; then
        handle_error 1 "Failed to enable Nginx service."
      fi
      ;;
  esac
  
  # Verify installation
  if service_installed "nginx"; then
    log_success "Nginx has been successfully installed."
    WEB_SERVER="nginx"
    return 0
  else
    handle_error 1 "Nginx installation verification failed."
  fi
}

# Function to prompt user to choose a web server
prompt_web_server() {
  local choice=""
  local install_result=0
  
  while [[ ! "$choice" =~ ^[1-2]$ ]]; do
    log_info "Please select a web server to install:"
    log_info "1) Apache"
    log_info "2) Nginx"
    echo -e "${YELLOW}[INFO]${NC} Enter your choice (1-2): " >&3
    read choice >&3
    
    case "$choice" in
      1)
        install_apache || handle_error 1 "Apache installation failed."
        ;;
      2)
        install_nginx || handle_error 1 "Nginx installation failed."
        ;;
      *)
        log_warning "Invalid choice. Please select 1 or 2."
        choice=""
        ;;
    esac
  done
}

# Function to setup web server
setup_web_server() {
  # First check if either Apache or Nginx is already installed
  if detect_web_server; then
    log_info "Using existing web server: $WEB_SERVER"
  else
    # If neither is installed, prompt the user to choose one
    log_warning "No web server detected. You need to install one."
    prompt_web_server
  fi
  
  if [ -z "$WEB_SERVER" ]; then
    handle_error 1 "Web server setup failed. No web server was selected or detected."
  fi
  
  log_success "Web server setup completed with: $WEB_SERVER"
}

# Function to configure web server with proxying for the application
configure_web_server() {
  # Extract domain from URL (without https://)
  DOMAIN=$(echo "$NODE_URL" | sed -E 's|https://([^:/]+).*|\1|')
  
  if [ -z "$DOMAIN" ]; then
    handle_error 1 "Failed to extract domain from NODE_URL: $NODE_URL"
  fi
  
  log_info "Configuring $WEB_SERVER for domain: $DOMAIN"
  
  if [ "$WEB_SERVER" = "nginx" ]; then
    # Create Nginx configuration file
    NGINX_CONF="/etc/nginx/sites-available/ag-node"
    
    # Create the Nginx configuration
    cat > /tmp/nginx-ag-node << EOL
server {
    listen 80;
    server_name ${DOMAIN};
    
    location / {
        proxy_pass http://localhost:26490;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    location /session/ {
        proxy_pass http://localhost:26490/session/;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOL
    
    # Move the configuration file and set up symbolic link
    if ! sudo mv /tmp/nginx-ag-node "$NGINX_CONF"; then
      handle_error 1 "Failed to create Nginx configuration file at $NGINX_CONF"
    fi
    
    # Enable the site if not already enabled
    if [ ! -f "/etc/nginx/sites-enabled/ag-node" ]; then
      if ! sudo ln -s "$NGINX_CONF" "/etc/nginx/sites-enabled/ag-node"; then
        handle_error 1 "Failed to enable Nginx site configuration."
      fi
    fi
    
    # Test configuration and reload Nginx
    log_info "Testing Nginx configuration..."
    if ! sudo nginx -t; then
      handle_error 1 "Nginx configuration test failed."
    fi
    
    log_info "Reloading Nginx to apply new configuration..."
    if ! sudo systemctl reload nginx; then
      handle_error 1 "Failed to reload Nginx."
    fi
    
    log_info "Nginx configuration created at $NGINX_CONF and enabled."
    
  elif [ "$WEB_SERVER" = "apache" ]; then
    # Create Apache configuration file
    APACHE_CONF="/etc/apache2/sites-available/ag-node.conf"
    
    # Create the Apache configuration
    cat > /tmp/apache-ag-node << EOL
<VirtualHost *:80>
    ServerName ${DOMAIN}
    
    ProxyPreserveHost On
    
    ProxyPass / http://localhost:26490/
    ProxyPassReverse / http://localhost:26490/
    
    <Location /session/>
        ProxyPass http://localhost:26490/session/
        ProxyPassReverse http://localhost:26490/session/
        
        # Support for WebSockets
        RewriteEngine On
        RewriteCond %{HTTP:Upgrade} =websocket [NC]
        RewriteRule /(.*)           ws://localhost:26490/\$1 [P,L]
        
        # Forward client IP and host
        RequestHeader set X-Forwarded-Proto "http"
        RequestHeader set X-Forwarded-Port "80"
        RequestHeader set X-Forwarded-For %{REMOTE_ADDR}s
    </Location>
    
    ErrorLog \${APACHE_LOG_DIR}/ag-node-error.log
    CustomLog \${APACHE_LOG_DIR}/ag-node-access.log combined
</VirtualHost>
EOL
    
    # Move the configuration file
    if ! sudo mv /tmp/apache-ag-node "$APACHE_CONF"; then
      handle_error 1 "Failed to create Apache configuration file at $APACHE_CONF"
    fi
    
    # Enable the site
    log_info "Enabling Apache site configuration..."
    if ! sudo a2ensite ag-node; then
      handle_error 1 "Failed to enable Apache site."
    fi
    
    # Test configuration and reload Apache
    log_info "Testing Apache configuration..."
    if ! sudo apache2ctl configtest; then
      handle_error 1 "Apache configuration test failed."
    fi
    
    log_info "Reloading Apache to apply new configuration..."
    if ! sudo systemctl reload apache2; then
      handle_error 1 "Failed to reload Apache."
    fi
    
    log_info "Apache configuration created at $APACHE_CONF and enabled."
  else
    handle_error 1 "No web server configuration created. Unsupported web server: $WEB_SERVER"
  fi
  
  log_success "Web server configured successfully for $DOMAIN"
  return 0
}

# Function to install Certbot for SSL certificates
install_certbot() {
  # Check if Certbot is already installed
  if package_installed "certbot"; then
    log_info "Certbot is already installed."
    return 0
  fi

  log_info "Installing Certbot for SSL certificates..."
  
  case "$OS_NAME" in
    ubuntu|debian)
      if ! sudo apt-get update -y; then
        handle_error 1 "Failed to update package lists."
      fi
      
      # Install Certbot and web server plugins
      if [ "$WEB_SERVER" = "apache" ]; then
        if ! sudo apt-get install -y certbot python3-certbot-apache; then
          handle_error 1 "Failed to install Certbot with Apache plugin."
        fi
        log_info "Certbot with Apache plugin installed."
      elif [ "$WEB_SERVER" = "nginx" ]; then
        if ! sudo apt-get install -y certbot python3-certbot-nginx; then
          handle_error 1 "Failed to install Certbot with Nginx plugin."
        fi
        log_info "Certbot with Nginx plugin installed."
      else
        if ! sudo apt-get install -y certbot; then
          handle_error 1 "Failed to install Certbot."
        fi
        log_info "Certbot installed (without web server plugin)."
      fi
      
      # Set up auto-renewal
      log_info "Setting up automatic certificate renewal..."
      if ! sudo systemctl enable certbot.timer; then
        handle_error 1 "Failed to enable automatic certificate renewal."
      fi
      
      if ! sudo systemctl start certbot.timer; then
        handle_error 1 "Failed to start automatic certificate renewal timer."
      fi
      
      log_info "Automatic renewal configured."
      ;;
  esac
  
  # Verify installation
  if package_installed "certbot"; then
    log_success "Certbot has been successfully installed."
    return 0
  else
    handle_error 1 "Certbot installation verification failed."
  fi
}

# Function to obtain SSL certificate using Certbot
obtain_ssl_certificate() {
  # Extract domain from URL (without https://)
  DOMAIN=$(echo "$NODE_URL" | sed -E 's|https://([^:/]+).*|\1|')
  
  if [ -z "$DOMAIN" ]; then
    handle_error 1 "Failed to extract domain from NODE_URL: $NODE_URL"
  fi
  
  log_info "Obtaining SSL certificate for $DOMAIN using Certbot..."
  
  # Check if certbot is installed
  if ! package_installed "certbot"; then
    log_info "Certbot is not installed. Installing it first..."
    install_certbot || handle_error 1 "Failed to install Certbot."
  fi
  
  # Create a prompt for user to confirm
  echo -e "${YELLOW}[INFO]${NC} Do you want to obtain an SSL certificate for $DOMAIN now? (y/n): " >&3
  read CONFIRM >&3
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_info "SSL certificate setup skipped."
    return 0
  fi
  
  # Check if web server is running
  if [ "$WEB_SERVER" = "nginx" ]; then
    if ! sudo systemctl is-active --quiet nginx 2>/dev/null; then
      log_warning "Nginx is not running. Starting it now..."
      if ! sudo systemctl start nginx 2>/dev/null; then
        handle_error 1 "Failed to start Nginx. Please check the configuration and start it manually."
      fi
      sleep 2  # Give Nginx time to start
    fi
  elif [ "$WEB_SERVER" = "apache" ]; then
    if ! sudo systemctl is-active --quiet apache2 2>/dev/null; then
      log_warning "Apache is not running. Starting it now..."
      if ! sudo systemctl start apache2 2>/dev/null; then
        handle_error 1 "Failed to start Apache. Please check the configuration and start it manually."
      fi
      sleep 2  # Give Apache time to start
    fi
  fi
  
  # Verify web server is now running
  if [ "$WEB_SERVER" = "nginx" ] && ! sudo systemctl is-active --quiet nginx 2>/dev/null; then
    handle_error 1 "Nginx failed to start. Please check the configuration and start it manually."
  elif [ "$WEB_SERVER" = "apache" ] && ! sudo systemctl is-active --quiet apache2 2>/dev/null; then
    handle_error 1 "Apache failed to start. Please check the configuration and start it manually."
  fi
  
  # Prompt for email (required for Let's Encrypt)
  echo -e "${YELLOW}[INFO]${NC} Enter your email address for certificate notifications: " >&3
  read EMAIL >&3
  
  if [ -z "$EMAIL" ]; then
    handle_error 1 "Email address is required for Let's Encrypt certificate."
  fi
  
  # Run Certbot to obtain certificate based on web server
  local certbot_output=""
  if [ "$WEB_SERVER" = "nginx" ]; then
    log_info "Running Certbot with Nginx plugin..."
    certbot_output=$(sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" 2>&1)
    certbot_exit_code=$?
  elif [ "$WEB_SERVER" = "apache" ]; then
    log_info "Running Certbot with Apache plugin..."
    certbot_output=$(sudo certbot --apache -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" 2>&1)
    certbot_exit_code=$?
  else
    handle_error 1 "No supported web server found. Unable to obtain certificate."
  fi
  
  # Check if certbot was successful
  if [ $certbot_exit_code -ne 0 ]; then
    log_info "Certbot output:"
    sudo docker logs ag-node
    handle_error 1 "Failed to obtain SSL certificate with exit code $certbot_exit_code."
  fi
  
  # Verify certificate was obtained
  if [[ -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
    log_success "SSL certificate obtained successfully for $DOMAIN"
    log_info "Certificate is installed and web server is configured to use HTTPS."
    return 0
  else
    handle_error 1 "Certificate directory not found after Certbot ran successfully. This is unexpected."
  fi
}

# Function to check if Docker is installed
docker_installed() {
  if package_installed "docker" && sudo docker --version; then
    return 0  # Docker is installed
  else
    return 1  # Docker is not installed
  fi
}

# Function to install Docker
install_docker() {
  if docker_installed; then
    log_info "Docker is already installed."
    return 0
  fi

  log_info "Installing Docker..."
  
  case "$OS_NAME" in
    ubuntu)
      # Update package index
      if ! sudo apt-get update -y; then
        handle_error 1 "Failed to update package lists."
      fi
      
      # Install prerequisites
      log_info "Installing Docker prerequisites..."
      if ! sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common; then
        handle_error 1 "Failed to install Docker prerequisites."
      fi
      
      # Add Docker's official GPG key
      log_info "Adding Docker's GPG key..."
      if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -; then
        handle_error 1 "Failed to add Docker's GPG key."
      fi
      
      # Add Docker repository
      log_info "Adding Docker repository..."
      if ! sudo add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"; then
        handle_error 1 "Failed to add Docker repository."
      fi
      
      # Update package index again
      if ! sudo apt-get update -y; then
        handle_error 1 "Failed to update package lists after adding Docker repository."
      fi
      
      # Install Docker CE
      log_info "Installing Docker CE..."
      if ! sudo apt-get install -y docker-ce docker-ce-cli containerd.io; then
        handle_error 1 "Failed to install Docker CE."
      fi
      ;;
      
    debian)
      # Update package index
      if ! sudo apt-get update -y; then
        handle_error 1 "Failed to update package lists."
      fi
      
      # Install prerequisites
      log_info "Installing Docker prerequisites..."
      if ! sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release; then
        handle_error 1 "Failed to install Docker prerequisites."
      fi
      
      # Add Docker's official GPG key
      log_info "Adding Docker's GPG key..."
      if ! curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
        handle_error 1 "Failed to add Docker's GPG key."
      fi
      
      # Add Docker repository
      log_info "Adding Docker repository..."
      if ! echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list; then
        handle_error 1 "Failed to add Docker repository."
      fi
      
      # Update package index again
      if ! sudo apt-get update -y; then
        handle_error 1 "Failed to update package lists after adding Docker repository."
      fi
      
      # Install Docker CE
      log_info "Installing Docker CE..."
      if ! sudo apt-get install -y docker-ce docker-ce-cli containerd.io; then
        handle_error 1 "Failed to install Docker CE."
      fi
      ;;
      
    *)
      handle_error 1 "Unsupported OS for Docker installation: $OS_NAME"
      ;;
  esac
  
  # Start and enable Docker service
  log_info "Starting and enabling Docker service..."
  if ! sudo systemctl start docker; then
    handle_error 1 "Failed to start Docker service."
  fi
  
  if ! sudo systemctl enable docker; then
    handle_error 1 "Failed to enable Docker service."
  fi
  
  # Verify installation
  if docker_installed; then
    log_success "Docker has been successfully installed."
    
    # Add current user to docker group to avoid using sudo
    log_info "Adding user $USER to the docker group..."
    if ! sudo usermod -aG docker "$USER"; then
      log_warning "Warning: Failed to add user to docker group. You may need to use sudo with docker commands."
    else
      log_info "Added $USER to the docker group. You may need to log out and back in for this to take effect."
    fi
    
    return 0
  else
    handle_error 1 "Docker installation verification failed."
  fi
}

# Function to securely get the private key and save to .ag-node.env file
setup_private_key() {
  log_info ""
  log_info "==============================================================="
  log_info "                   PRIVATE KEY CONFIGURATION                    "
  log_info "==============================================================="
  log_info ""
  log_info "You need to obtain a private key from the Alliance Games dashboard."
  log_info "This key is required for your node to connect to the network."
  log_info ""
  log_info "You can obtain your private key at: https://dashboard.alliancegames.com/nodes"
  log_info "(This is a placeholder URL - your administrator will provide the correct link)"
  log_info ""
  
  # Define the .ag-node.env file path
  ENV_FILE="$(pwd)/.ag-node.env"
  
  # Check if .ag-node.env file already exists
  if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}[INFO]${NC} An existing .ag-node.env file was found. Do you want to overwrite it? (y/n): " >&3
    read OVERWRITE >&3
    if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
      log_info "Keeping existing .ag-node.env file."
      return 0
    fi
  fi
  
  # Read the private key securely without echo
  log_info "Please enter your private key (input will be hidden):"
  read -s PRIVATE_KEY >&3
  log_info ""
  
  # Confirm the key
  log_info "Please confirm your private key (input will be hidden):"
  read -s CONFIRM_KEY >&3
  log_info ""
  
  # Check if keys match
  if [ "$PRIVATE_KEY" != "$CONFIRM_KEY" ]; then
    log_info "Error: Private keys do not match. Please try again."
    setup_private_key
    return
  fi
  
  # Validate that the key is not empty
  if [ -z "$PRIVATE_KEY" ]; then
    handle_error 1 "Private key cannot be empty."
  fi
  
  # Ensure we have a valid NODE_URL
  if [ -z "$NODE_URL" ]; then
    handle_error 1 "NODE_URL is not set. Cannot create .ag-node.env file."
  fi
  
  # Ensure we have a valid WEB_SERVER
  if [ -z "$WEB_SERVER" ]; then
    handle_error 1 "WEB_SERVER is not set. Cannot create .ag-node.env file."
  fi
  
  # Create the .ag-node.env file with the private key
  log_info "Creating .ag-node.env file..."
  if ! echo "# Alliance Games Node Environment Configuration" > "$ENV_FILE"; then
    handle_error 1 "Failed to create .ag-node.env file."
  fi
  
  if ! echo "# Created on: $(date)" >> "$ENV_FILE"; then
    handle_error 1 "Failed to write to .ag-node.env file."
  fi
  
  if ! echo "NODE_URL=$NODE_URL" >> "$ENV_FILE"; then
    handle_error 1 "Failed to write to .ag-node.env file."
  fi
  
  if ! echo "WEB_SERVER=$WEB_SERVER" >> "$ENV_FILE"; then
    handle_error 1 "Failed to write to .ag-node.env file."
  fi
  
  if ! echo "PRIVATE_KEY=$PRIVATE_KEY" >> "$ENV_FILE"; then
    handle_error 1 "Failed to write to .ag-node.env file."
  fi
  
  # Set strict permissions on the .ag-node.env file (only owner can read/write)
  if ! chmod 600 "$ENV_FILE"; then
    handle_error 1 "Failed to set permissions on .ag-node.env file."
  fi
  
  log_success "Private key has been saved to $ENV_FILE with restricted permissions."
  log_info "Only the owner of the file can read or modify it."
  
  return 0
}

# Function to start the AG Node Docker container
start_docker_container() {
  log_info ""
  log_info "==============================================================="
  log_info "              STARTING AG-NODE DOCKER CONTAINER                "
  log_info "==============================================================="
  log_info ""
  
  # Define environment file path
  ENV_FILE="$(pwd)/.ag-node.env"
  
  # Check if the .ag-node.env file exists
  if [ ! -f "$ENV_FILE" ]; then
    handle_error 1 ".ag-node.env file not found at $ENV_FILE. Cannot start the Docker container."
  fi
  
  # Create required directories for volumes
  log_info "Creating required directories..."
  if ! sudo mkdir -p /etc/ag; then
    handle_error 1 "Failed to create /etc/ag directory."
  fi
  
  if ! sudo chmod 755 /etc/ag; then
    handle_error 1 "Failed to set permissions on /etc/ag directory."
  fi
  
  # Check if a container with the same name already exists
  if sudo docker ps -a --format '{{.Names}}' | grep -q '^ag-node$'; then
    log_info "A Docker container named 'ag-node' already exists."
    echo -e "${YELLOW}[INFO]${NC} Do you want to remove it and create a new one? (y/n): " >&3
    read REMOVE >&3
    if [[ "$REMOVE" =~ ^[Yy]$ ]]; then
      log_info "Stopping and removing existing container..."
      
      if ! sudo docker stop ag-node; then
        log_warning "Warning: Failed to stop existing ag-node container."
      fi
      
      if ! sudo docker rm ag-node; then
        handle_error 1 "Failed to remove existing ag-node container."
      fi
    else
      log_info "Keeping existing container. Docker setup skipped."
      return 0
    fi
  fi
  
  log_info "Starting AG Node Docker container..."
  
  # Pull the latest image
  log_info "Pulling the latest AG Node image..."
  if ! sudo docker pull registry.ag.chainofalliance.com/ag-node:latest; then
    handle_error 1 "Failed to pull the AG Node Docker image. Please check your internet connection and Docker Hub access."
  fi
  
  # Start the container
  log_info "Starting AG Node container..."
  if ! sudo docker run -d \
    --add-host=host.docker.internal:host-gateway \
    --env-file="$ENV_FILE" \
    --restart always \
    -p 26490:26490 \
    --name ag-node \
    -v /etc/ag:/etc/ag \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    registry.ag.chainofalliance.com/ag-node:latest; then
    handle_error 1 "Failed to start AG Node Docker container."
  fi
  
  # Give the container a moment to start
  sleep 5
  
  # Check if container started successfully
  if sudo docker ps --format '{{.Names}}' | grep -q '^ag-node$'; then
    log_success "AG Node Docker container started successfully!"
    log_info "Container logs can be viewed with: sudo docker logs ag-node"
    return 0
  else
    log_info "Container logs:"
    sudo docker logs ag-node
    handle_error 1 "AG Node container failed to start or immediately exited."
  fi
}

# Main script execution starts here

# Enable error handling mode - do not exit automatically for the main block
set +e

# Ensure script is run with sudo privileges
check_sudo

# Call the function to determine OS
determine_os

# Install necessary dependencies
if ! install_dependencies; then
  handle_error 1 "Failed to install required dependencies."
fi

# Prompt for node URL
prompt_node_url

# Setup web server (Apache or Nginx)
if ! setup_web_server; then
  handle_error 1 "Web server setup failed."
fi

# Configure web server with proper site configuration
if ! configure_web_server; then
  handle_error 1 "Web server configuration failed."
fi

# Install Certbot for SSL certificates
if ! install_certbot; then
  handle_error 1 "Certbot installation failed."
fi

# Obtain SSL certificate
if ! obtain_ssl_certificate; then
  handle_error 1 "SSL certificate setup failed."
fi

# Install Docker if needed
if ! install_docker; then
  handle_error 1 "Docker installation failed."
fi

# Setup private key in .ag-node.env file
if ! setup_private_key; then
  handle_error 1 "Private key setup failed."
fi

# Start the AG Node Docker container
if ! start_docker_container; then
  handle_error 1 "Docker container startup failed."
fi

log_info ""
log_info "==============================================================="
log_info "                  INSTALLATION COMPLETE                        "
log_info "==============================================================="
log_info ""
log_success "Setup completed with:"
log_info "- Node URL: $NODE_URL"
log_info "- Web Server: $WEB_SERVER"
log_info "- Private key saved to: $(pwd)/.ag-node.env"
log_info "- Docker container name: ag-node"
log_info ""
log_info "Your node should now be accessible at: $NODE_URL"
log_info ""
log_info "To check the status of your node, run: sudo docker logs ag-node"
log_info "To stop your node, run: sudo docker stop ag-node"
log_info "To start your node again, run: sudo docker start ag-node"
log_info ""

exit 0
