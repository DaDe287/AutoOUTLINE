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
iptables -A FORWARD -p tcp --dport 6881:6999 -j DROP
iptables -A FORWARD -p udp --dport 6881:6999 -j DROP

# Installing Outline
echo "Y" | sudo wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh | bash
