#!/bin/bash
#Set some env
echo "--> Set some env"
LOCAL_HOST=$(hostname)
LOCAL_DOMAIN=$(dnsdomainname)
LOCAL_FQDN=$(hostname -f)
LOCAL_IP=$(hostname -I | awk '{print $1}')
DOMAIN_OSE_APP_KEYFILE=/var/named/${DOMAIN_OSE_APP}.key
DOMAIN_OSE_HOST_KEYFILE=/var/named/${DOMAIN_OSE_HOST}.key

#Install/remove components
echo "--> Install/remove components"
yum -y remove NetworkManager*
yum -y install bind bind-utils lokkit iptables-services

systemctl stop firewalld
systemctl disable firewalld
systemctl enable iptables
systemctl start iptables

lokkit --service=dns
lokkit --service=ssh

systemctl enable named
systemctl stop named

#Clean previous installation
echo "--> Clean previous installation"
rm -vf /var/named/K*
rm -rf /var/named/zones
mkdir -p /var/named/zones
rm -rvf /var/named/dynamic
mkdir -vp /var/named/dynamic

#Prepare keys
echo "--> Prepare keys"
rndc-confgen -a -r /dev/urandom

pushd /var/named
dnssec-keygen -a HMAC-SHA256 -b 256 -n USER -r /dev/urandom ${DOMAIN_OSE_APP}
DOMAIN_OSE_APP_KEY="$(grep Key: K${DOMAIN_OSE_APP}*.private | cut -d ' ' -f 2)"
popd
cat <<EOF > /var/named/${DOMAIN_OSE_APP}.key
key ${DOMAIN_OSE_APP} {
  algorithm HMAC-SHA256;
  secret "${DOMAIN_OSE_APP_KEY}";
};
EOF

pushd /var/named
dnssec-keygen -a HMAC-SHA256 -b 256 -n USER -r /dev/urandom ${DOMAIN_OSE_HOST}
DOMAIN_OSE_HOST_KEY="$(grep Key: K${DOMAIN_OSE_HOST}*.private | cut -d ' ' -f 2)"
popd
cat <<EOF > /var/named/${DOMAIN_OSE_HOST}.key
key ${DOMAIN_OSE_HOST} {
  algorithm HMAC-SHA256;
  secret "${DOMAIN_OSE_HOST_KEY}";
};
EOF

restorecon -v /etc/rndc.* /etc/named.*;
chown -v root:named /etc/rndc.key;
chmod -v 640 /etc/rndc.key;

#Prepare zones files
echo "--> Prepare zones files"
cat <<EOF > /var/named/zones/${DOMAIN_OSE_HOST}.db
\$ORIGIN  .
\$TTL 1  ;  1 seconds (for testing only)
${DOMAIN_OSE_HOST}               IN SOA ${LOCAL_FQDN}.  hostmaster.${LOCAL_DOMAIN}.  (
                                 2011112904  ;  serial
                                 60  ;  refresh (1 minute)
                                 15  ;  retry (15 seconds)
                                 1800  ;  expire (30 minutes)
                                 10  ; minimum (10 seconds)
                                 )
                         NS      ${LOCAL_FQDN}.
                         MX      10 mail.${DOMAIN_OSE_HOST}.
\$ORIGIN ${DOMAIN_OSE_HOST}.
${LOCAL_HOST}           A       127.0.0.1
                        A       ${LOCAL_DNS}
\$TTL 180        ; 3 minutes
EOF

cat <<EOF > /var/named/dynamic/${DOMAIN_OSE_APP}.db
\$ORIGIN .
\$TTL 1 ; 1 seconds (for testing only)
${DOMAIN_OSE_APP}                IN SOA  ${LOCAL_FQDN}. hostmaster.${LOCAL_DOMAIN}. (
                                 2011112904  ; serial
                                 60          ; refresh (1 minute)
                                 15          ; retry (15 seconds)
                                 1800        ; expire (30 m inutes)
                                 10          ; minimum (10 seconds)
                                 )
                         NS      ${LOCAL_FQDN}.
                         MX      10 mail.${DOMAIN_OSE_APP}.
\$ORIGIN ${DOMAIN_OSE_APP}.
EOF

#Prepare conf file
echo "--> Prepare conf file"
cat <<EOF > /etc/named.conf
options {
  listen-on port 53 { any; };
  directory "/var/named";
  dump-file "/var/named/data/cache_dump.db";
  statistics-file "/var/named/data/named_stats.txt";
  memstatistics-file "/var/named/data/named_mem_stats.txt";
  allow-query { any; };
  recursion no;
  dnssec-enable yes;
  dnssec-validation yes;
  /* Path to ISC DLV key */
  bindkeys-file "/etc/named.iscdlv.key";
  managed-keys-directory "/var/named";
  pid-file "/run/named/named.pid";
  session-keyfile "/run/named/session.key";
};

logging {
  channel default_debug {
    file "data/named.run";
    severity dynamic;
  };
};

// use the default rndc key
include "/etc/rndc.key";
include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
include "${DOMAIN_OSE_APP_KEYFILE}";
include "${DOMAIN_OSE_HOST_KEYFILE}";

controls {
  inet 127.0.0.1 port 953
  allow { 127.0.0.1; } keys { "rndc-key"; };
};

zone "." IN {
        type hint;
        file "named.ca";
};

zone "${DOMAIN_OSE_HOST}" IN {
  type master;
  file "zones/${DOMAIN_OSE_HOST}.db";
  allow-update { key ${DOMAIN_OSE_HOST} ; } ;
};

zone "${DOMAIN_OSE_APP}" IN {
  type master;
  file "dynamic/${DOMAIN_OSE_APP}.db";
  allow-update { key ${DOMAIN_OSE_APP} ; } ;
};

EOF

#Restore file ownership
#This sectio has to be hardened
echo "--> Restore file ownership"
chown -R named:named /var/named/
restorecon -rv /var/named;

chown root:named /etc/named.conf
restorecon /etc/named.conf

#Start services
echo "--> Start services"
systemctl start named.service ; 

#Test services
echo "--> Test services"
echo "update add test.${DOMAIN_OSE_APP} 86400 a 1.1.1.1
send" | nsupdate -v -k "${DOMAIN_OSE_APP_KEYFILE}"
dig @127.0.0.1 test.${DOMAIN_OSE_APP}
if [ $? = 0 ]
then
  echo "DNS Setup for ${DOMAIN_OSE_APP} was successful!"
  echo "update delete test.${DOMAIN_OSE_APP} 86400 a 1.1.1.1
  send" | nsupdate -v -k "${DOMAIN_OSE_APP_KEYFILE}"
else
  echo "DNS Setup for ${DOMAIN_OSE_APP} failed"
fi

echo "update add test.${DOMAIN_OSE_HOST} 86400 a 1.1.1.1
send" | nsupdate -v -k "${DOMAIN_OSE_HOST_KEYFILE}"
dig @127.0.0.1 test.${DOMAIN_OSE_HOST}
if [ $? = 0 ]
then
  echo "DNS Setup for ${DOMAIN_OSE_HOST} was successful!"
  echo "update delete test.${DOMAIN_OSE_HOST} 86400 a 1.1.1.1
  send" | nsupdate -v -k "${DOMAIN_OSE_HOST_KEYFILE}"
else
  echo "DNS Setup for ${DOMAIN_OSE_HOST} failed"
fi

echo Script $0 ended 
