#!/bin/bash -xe

if [[ $# -lt 3 ]] ; then
    echo "Usage: $0 <installerUrl> <dataVolume> <appVolume>"
    echo ""
    echo "Example: $0 'https://example.org/package.tar.gz' /dev/sda /dev/sdb dev"
    exit 1
fi

JIRAInstallerUrl=$1
EC2DataVolumeMount=$2
EC2AppVolumeMount=$3

# Create directories
mkdir -p /opt/atlassian/ /var/atlassian/application-data/crowd

# Wait until the volume shows up
while [ ! -e ${EC2DataVolumeMount} ]; do echo Waiting for EBS Data volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2DataVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2DataVolumeMount}    /var/atlassian/application-data/crowd xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Wait until the volume shows up
while [ ! -e ${EC2AppVolumeMount} ]; do echo Waiting for EBS App volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2AppVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2AppVolumeMount}     /opt/atlassian/crowd                xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Mount the volumes on current boot
mount -a

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

# Add the custom banner on the login page
patch /opt/atlassian/crowd/crowd-webapp/console/login.jsp /tmp/cots-mods-crowd/login.jsp.patch

# Refresh systemd daemons since we've added a new unit file
# start Crowd and enable startup at boot-time
systemctl daemon-reload
systemctl enable crowd --now

# Cleanup
rm -r /tmp/cots-mods-crowd /tmp/pkg.zip /tmp/atlassian-crowd.tar.gz
