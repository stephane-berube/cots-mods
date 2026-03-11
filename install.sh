#!/bin/bash -xe

if [[ $# -lt 3 ]] ; then
    echo "Usage: $0 <installerUrl> <dataVolume> <appVolume> [Environment] [crowdDomain] [crowdIntDomain]"
    echo ""
    echo "Example: $0 'https://example.org/package.tar.gz' /dev/sda /dev/sdb dev crowd.dev.example.org crowd-int.dev.example.org"
    exit 1
fi

CrowdArchiveUrl=$1
EC2DataVolumeMount=$2
EC2AppVolumeMount=$3
Environment=$4
crowdDomain=$5
crowdIntDomain=$6

# Create directories
mkdir -p /opt/atlassian/ /var/atlassian/application-data/crowd

# Wait until the volume shows up
while [ ! -e "${EC2DataVolumeMount}" ]; do echo Waiting for EBS Data volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2DataVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2DataVolumeMount}    /var/atlassian/application-data/crowd xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Wait until the volume shows up
while [ ! -e "${EC2AppVolumeMount}" ]; do echo Waiting for EBS App volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2AppVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2AppVolumeMount}     /opt/atlassian/                xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Mount the volumes on current boot
mount -a

# Create "crowd" directory on the mounted volume
mkdir /opt/atlassian/crowd

# Install deps
yum install -y fontconfig patch

# Get and extract Crowd archive
wget "${CrowdArchiveUrl}" -O /tmp/atlassian-crowd.tar.gz
tar -C /opt/atlassian -xf /tmp/atlassian-crowd.tar.gz
rename atlassian-crowd* crowd /opt/atlassian/*

# Create user, set permissions
adduser crowd
chown -R crowd:crowd /opt/atlassian /var/atlassian/application-data

# Set crowd home directory
echo 'crowd.home=/var/atlassian/application-data/crowd' >> /opt/atlassian/crowd/crowd-webapp/WEB-INF/classes/crowd-init.properties

# Setup logging to be logrotate-friendly
cat /tmp/cots-mods-crowd/logging.properties.suffix >> /opt/atlassian/crowd/apache-tomcat/conf/logging.properties
mv /tmp/cots-mods-crowd/crowd.logrotate /etc/logrotate.d/crowd.conf

# Get RDS root cert for TLS connection
wget https://s3.amazonaws.com/rds-downloads/rds-ca-2019-root.pem \
        -O /var/atlassian/application-data/crowd/rds-ca-2019-root.pem

# Copy our systemd unit file
mv /tmp/cots-mods-crowd/crowd.service /etc/systemd/system/crowd.service

# Refresh systemd daemons since we've added a new unit file
systemctl daemon-reload

# Make OAuth work when HTTPS is terminated at the ALB (for "Service Accounts")
patch "${new_install_dir}"/apache-tomcat/bin/setenv.sh ./setenv.sh.patch

# Redirect homepage "setup" page to the login page
# See: https://confluence.atlassian.com/crowdkb/redirect-crowd-server-setup-page-to-crowd-webapp-login-page-839978419.html
cp /opt/atlassian/crowd/crowd-webapp/WEB-INF/lib/urlrewritefilter-5.1.3.jar /opt/atlassian/crowd/apache-tomcat/lib/
cp /opt/atlassian/crowd/crowd-webapp/WEB-INF/urlrewrite.xml /opt/atlassian/crowd/apache-tomcat/webapps/ROOT/WEB-INF
patch /opt/atlassian/crowd/apache-tomcat/webapps/ROOT/WEB-INF/urlrewrite.xml /tmp/cots-mods-crowd/urlrewrite.xml.patch
patch /opt/atlassian/crowd/apache-tomcat/webapps/ROOT/WEB-INF/web.xml /tmp/cots-mods-crowd/web.xml.patch

# Trust store
trust_store_dir="/var/atlassian/application-data/crowd/upmconfig/truststore"
mkdir -p "${trust_store_dir}"
wget --directory-prefix "${trust_store_dir}" https://confluence.atlassian.com/upm/files/1489470540/1489470538/1/1736436578459/atlassian_ca_bundle-v1.tar.gz 
tar -C "${trust_store_dir}" -xf "${trust_store_dir}/atlassian_ca_bundle-v1.tar.gz"
rm "${trust_store_dir}/atlassian_ca_bundle-v1.tar.gz"
sudo chown -R root:root "${trust_store_dir}"

# If we've been given a url, setup server.xml
if [ -n "${crowdDomain}" ]; then
    patch /opt/atlassian/crowd/apache-tomcat/conf/server.xml /tmp/cots-mods-crowd/server.xml.patch
    sed -i "s/{{ ised-crowd-domain }}/${crowdDomain}/g" /opt/atlassian/crowd/apache-tomcat/conf/server.xml
fi

# If we've been given a "int" url, add additional connector to server.xml
if [ -n "${crowdIntDomain}" ]; then
    sed -i '/<Service name="Catalina">/{
        s/<Service name="Catalina">//g
        r server.xml-crowd-int
    }' /opt/atlassian/crowd/apache-tomcat/conf/server.xml

    sed -i "s/{{ ised-crowd-int-domain }}/${crowdIntDomain}/g" /opt/atlassian/crowd/apache-tomcat/conf/server.xml
fi

# Do a couple of things differently based on the environment
if [ "${Environment}" == "prod" ]; then
    # Enable Crowd service at boot-time
    systemctl enable crowd
else
    # Delay Crowd startup when the EC2 is booting up (see comment in crowd.timer for more details)
    mv /tmp/cots-mods-crowd/crowd.timer /etc/systemd/system/crowd.timer

    # Enable Crowd service at boot-time via timer
    systemctl enable crowd.timer
fi

# Start Crowd for this current boot
systemctl start crowd

# Cleanup
rm -r /tmp/cots-mods-crowd /tmp/pkg.zip /tmp/atlassian-crowd.tar.gz
