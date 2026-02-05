# Begin
clear

# Updating Installing pkgs etc
apt install sudo
sudo apt update && sudo apt upgrade -y

# UFW
# COMMON RULES
echo "Y" | sudo apt install ufw
sudo ufw allow 80/tcp
sudo ufw allow 8080/tcp
sudo ufw allow 22/tcp
sudo ufw allow 443
sudo ufw allow 1024:65535/udp
sudo ufw allow 1024:65535/tcp
echo "y" | sudo ufw enable

# iptables
# Block Torrents trafic
echo "Y" | sudo apt install iptables
# DHT
iptables -A OUTPUT -p udp --dport 6881:6889 -j DROP
iptables -A OUTPUT -p udp --dport 51413 -j DROP

# PEX / LSD
iptables -A OUTPUT -p udp -m string --algo bm --string "BitTorrent protocol" -j DROP

# Block Any scanners to the server
sudo traffic-guard full \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list \
  --enable-logging

# Installing Outline
echo "Y" | sudo wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh | bash
