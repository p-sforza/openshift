#!/bin/bash

# Prepare the disk, assign it to LVM and create fs
echo "--> Setting up disk..."
sfdisk ${NFS_DISK} << EOF
;
EOF

pvcreate ${NFS_PARTITION}
vgcreate ${NFS_VG_NAME} ${NFS_PARTITION}
lvcreate -l 100%FREE -n ${NFS_LV_NAME} ${NFS_VG_NAME}
mkfs.xfs -q -f /dev/${NFS_VG_NAME}/${NFS_LV_NAME}

# Install and configure NFS
echo "--> Installing NFS..."
yum -y install nfs-utils rpcbind 

echo "Configuring NFS..."
sed -i -e 's/^RPCMOUNTDOPTS.*/RPCMOUNTDOPTS="-p 20048"/' -e 's/^STATDARG.*/STATDARG="-p 50825"/' /etc/sysconfig/nfs

echo "Setting sysctl params..."
grep -q fs.nlm /etc/sysctl.conf
if [ $? -eq 1 ]
then
  sed -i -e '$afs.nfs.nlm_tcpport=53248' -e '$afs.nfs.nlm_udpport=53248' /etc/sysctl.conf
fi

# Mount the Volume
mkdir -p ${NFS_MNT_POINT}
grep -q "/dev/${NFS_VG_NAME}/${NFS_LV_NAME}" /etc/fstab
if [ $? -eq 1 ]
then
cat << EOF >> /etc/fstab
/dev/${NFS_VG_NAME}/${NFS_LV_NAME}        ${NFS_MNT_POINT}              xfs defaults 0 0
EOF
fi
mount -a
sleep 5
echo "--> Create local mounts..."
mkdir -p ${NFS_MNT_POINT}/{registry,vol1,vol2,vol3,es-storage}
chmod -R 777 ${NFS_MNT_POINT}/*
chown -R nfsnobody:nfsnobody ${NFS_MNT_POINT}

# Export the NFS partition 
echo "--> Export mounts..."
cat << EOF >> /etc/exports
${NFS_MNT_POINT}/registry *(insecure,rw,root_squash)
${NFS_MNT_POINT}/vol1 *(insecure,rw,root_squash)
${NFS_MNT_POINT}/vol2 *(insecure,rw,root_squash)
${NFS_MNT_POINT}/vol3 *(insecure,rw,root_squash)
${NFS_MNT_POINT}/es-storage *(insecure,rw,root_squash)
EOF
exportfs -a

# Setup firewall
echo "--> Setting up firewall..."
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 111 -j ACCEPT
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 2049 -j ACCEPT
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 20048 -j ACCEPT
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 50825 -j ACCEPT
iptables -I INPUT -p tcp -m state --state NEW -m tcp --dport 53248 -j ACCEPT
iptales-save

echo "--> Setting up services..."
systemctl enable rpcbind nfs-server
systemctl start rpcbind nfs-server nfs-lock
systemctl start nfs-idmap
sysctl -p
systemctl restart nfs

echo "--> Setting NFS seboolean..."
setsebool -P virt_use_nfs=true
