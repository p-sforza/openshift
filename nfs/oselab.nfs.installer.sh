#!/bin/bash

echo "Setting up disk..."
parted -s /dev/vdb mklabel msdos
parted -s /dev/vdb mkpart primary ext4 0 100%
mkfs.ext4 /dev/vdb1
mkdir /srv/nfs
mount /dev/vdb1 /srv/nfs
mkdir -p /srv/nfs/{registry,vol1,vol2,vol3,es-storage}
chmod -R 777 /srv/nfs/*
chown -R nfsnobody:nfsnobody /srv/nfs

## We need to update /etc/fstab in this script <sborenst>

echo "Setting up exports..."
cat << EOF > /etc/exports
/srv/nfs/registry *(rw,root_squash)
/srv/nfs/vol1 *(rw,root_squash)
/srv/nfs/vol2 *(rw,root_squash)
/srv/nfs/vol3 *(rw,root_squash)
/srv/nfs/es-storage *(rw,root_squash)

EOF

echo "Setting up firewall..."
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 111 -j ACCEPT
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 2049 -j ACCEPT
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 20048 -j ACCEPT
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 50825 -j ACCEPT
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 53248 -j ACCEPT

echo "Configuring NFS..."
sed -i -e 's/^RPCMOUNTDOPTS.*/RPCMOUNTDOPTS="-p 20048"/' -e 's/^STATDARG.*/STATDARG="-p 50825"/' /etc/sysconfig/nfs

grep -q "dport 53248" /etc/sysconfig/iptables
if [ $? -eq 1 ]
then
sed -i -e '/^:OUTPUT/a -I INPUT -p tcp -m state --state NEW -m tcp --dport 53248 -j ACCEPT\
-I INPUT -p tcp -m state --state NEW -m tcp --dport 50825 -j ACCEPT\
-I INPUT -p tcp -m state --state NEW -m tcp --dport 20048 -j ACCEPT\
-I INPUT -p tcp -m state --state NEW -m tcp --dport 2049 -j ACCEPT\
-I INPUT -p tcp -m state --state NEW -m tcp --dport 111 -j ACCEPT' \
  /etc/sysconfig/iptables
fi

echo "Setting sysctl params..."
grep -q fs.nlm /etc/sysctl.conf
if [ $? -eq 1 ]
then
  sed -i -e '$afs.nfs.nlm_tcpport=53248' -e '$afs.nfs.nlm_udpport=53248' /etc/sysctl.conf
fi

echo "Setting up services..."
systemctl enable rpcbind nfs-server
systemctl start rpcbind nfs-server nfs-lock
systemctl start nfs-idmap
sysctl -p
systemctl restart nfs

echo "Setting NFS seboolean..."
setsebool -P virt_use_nfs=true
