clear
sudo apt update && sudo apt upgrade -y
sudo apt install ufw
sudo ufw allow 80/tcp
sudo ufw allow 8080/tcp
sudo ufw allow 22/tcp
sudo ufw allow 1024:65535/udp
sudo ufw allow 1024:65535/tcp
echo "y" | sudo ufw enable
echo "Y" | sudo wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh | bash
