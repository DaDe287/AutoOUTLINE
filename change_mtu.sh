sudo ip link set dev eth0 mtu 1000

echo "      mtu 1000" > /etc/network/interfaces
sudo systemctl restart networking

echo "{ "mtu": 1000 }" > /etc/docker/daemon.json
sudo systemctl daemon-reload

sudo systemctl restart docker
