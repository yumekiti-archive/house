apt update && \
apt install ansible && \
git clone https://github.com/yumekiti/house.git && \
cd house && \
ansible-playbook main.yml