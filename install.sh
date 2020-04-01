#!/bin/bash -xe

if [[ $# -lt 4 ]] ; then
    echo "Usage: $0 <installerUrl> <dataVolume> <appVolume> <Environment>"
    echo ""
    echo "Example: $0 'https://example.org/installer.bin' /dev/sda /dev/sdb dev"
    exit 1
fi

JIRAInstallerUrl=$1
EC2DataVolumeMount=$2
EC2AppVolumeMount=$3
Environment=$4

# Create directories
mkdir -p /opt/atlassian/jira /var/atlassian/application-data/jira

# Wait until the data volume shows up
while [ ! -e "${EC2DataVolumeMount}" ]; do echo Waiting for EBS Data volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2DataVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2DataVolumeMount}    /var/atlassian/application-data/jira xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Wait until the app volume shows up
while [ ! -e "${EC2AppVolumeMount}" ]; do echo Waiting for EBS App volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2AppVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2AppVolumeMount}     /opt/atlassian/jira                xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Mount the volumes on current boot
mount -a

# Install deps
yum install -y fontconfig patch java-1.8.0-openjdk

# Get and run JIRA installer
wget "${JIRAInstallerUrl}" -O /tmp/installer.bin
chmod u+x /tmp/installer.bin
yes '' | /tmp/installer.bin

# Stop the running JIRA instance
service jira stop

# Overwrite the JIRA service with our systemd-compatible one
mv /tmp/cots-mods-jira/jira-initd /etc/init.d/jira

# Disable the old JIRA boot-time startup
systemctl disable jira

# Copy our systemd unit file
mv /tmp/cots-mods-jira/jira.service /etc/systemd/system/jira.service

# Copy our JIRA configs over and fix permissions
mv /tmp/cots-mods-jira/jira-config.properties /var/atlassian/application-data/jira/
chown jira /var/atlassian/application-data/jira/jira-config.properties

# Comment out the default Connector, and uncomment the reverse-proxied HTTPS one
patch /opt/atlassian/jira/conf/server.xml /tmp/cots-mods-jira/https--server.xml.patch

# Setup logging to be logrotate-friendly
cat /tmp/cots-mods-jira/logging.properties.suffix >> /opt/atlassian/jira/conf/logging.properties
patch /opt/atlassian/jira/conf/server.xml /tmp/cots-mods-jira/access-log--server.xml.patch
mv /tmp/cots-mods-jira/jira.logrotate /etc/logrotate.d/jira.conf

# If we're not on Prod, turn off email notifications
if [ "${Environment}" != "prod" ]
then
  sed -i 's/#DISABLE_NOTIFICATIONS=/DISABLE_NOTIFICATIONS=/' /opt/atlassian/jira/bin/setenv.sh
fi

# Update email header to truncate quoted text from email replies
# see: https://confluence.atlassian.com/jirakb/remove-previous-content-from-incoming-email-from-jira-server-in-microsoft-outlook-223218415.html
patch /opt/atlassian/jira/atlassian-jira/WEB-INF/classes/templates/email/html/includes/header.vm /tmp/cots-mods-jira/header.vm.patch

# Refresh systemd daemons since we've added a new unit file
# start JIRA and enable startup at boot-time
systemctl daemon-reload
systemctl enable jira --now

# Cleanup
rm -r /tmp/cots-mods-jira /tmp/installer.bin /tmp/pkg.zip