#!/bin/bash -xe

if [[ $# -lt 3 ]] ; then
    echo "Usage: $0 <installerUrl> <dataVolume> <appVolume>"
    echo ""
    echo "Example: $0 'https://example.org/installer.bin' /dev/sda /dev/sdb dev"
    exit 1
fi

JIRAInstallerUrl=$1
EC2DataVolumeMount=$2
EC2AppVolumeMount=$3

# Create directories
mkdir -p /opt/atlassian/confluence /var/atlassian/application-data/confluence

# Wait until the volume shows up
while [ ! -e ${EC2DataVolumeMount} ]; do echo Waiting for EBS Data volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EBSDataMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2DataVolumeMount}    /var/atlassian/application-data/confluence xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Wait until the volume shows up
while [ ! -e ${EBSAppMount} ]; do echo Waiting for EBS App volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2AppVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2AppVolumeMount}     /opt/atlassian/confluence                xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Mount the volumes on current boot
mount -a

# Install deps
yum install -y fontconfig patch java-1.8.0-openjdk

# Get and run Confluence installer
wget "${ConfluenceInstallerUrl}" -O /tmp/installer.bin
chmod u+x /tmp/installer.bin
yes '' | /tmp/installer.bin

# Stop the running Confluence instance
service confluence stop

# Setup logging to be logrotate-friendly
cat /tmp/cots-mods-confluence/logging.properties.suffix >> /opt/atlassian/confluence/conf/logging.properties
mv /tmp/cots-mods-confluence/confluence.logrotate /etc/logrotate.d/confluence.conf

# Get RDS root cert for TLS connection
wget https://s3.amazonaws.com/rds-downloads/rds-ca-2019-root.pem \
        -O /var/atlassian/application-data/confluence/rds-ca-2019-root.pem

# Disable the old Confluence boot-time startup
systemctl disable confluence

# Copy our systemd unit file
mv /tmp/cots-mods-confluence/confluence.service /etc/systemd/system/confluence.service

# Refresh systemd daemons since we've added a new unit file
# start Confluence and enable startup at boot-time
systemctl daemon-reload
systemctl enable confluence --now

# Cleanup
rm -r /tmp/cots-mods-confluence /tmp/pkg.zip /tmp/installer.bin
