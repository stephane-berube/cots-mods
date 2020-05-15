#!/bin/bash -xe

if [[ $# -lt 4 ]] ; then
    echo "Usage: $0 <installerUrl> <dataVolume> <appVolume> <Environment> [JIRAUrl]"
    echo ""
    echo "Example: $0 'https://example.org/installer.bin' /dev/sda /dev/sdb dev"
    exit 1
fi

JIRAInstallerUrl=$1
EC2DataVolumeMount=$2
EC2AppVolumeMount=$3
Environment=$4
JIRAUrl=$5

# Create mountpoints
mkdir -p /opt/atlassian /var/atlassian/application-data/jira

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
echo "${EC2AppVolumeMount}     /opt/atlassian                xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Mount the volumes on current boot
mount -a

# Create JIRA install directory
mkdir /opt/atlassian/jira

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

# Refresh systemd daemons since we've added a new unit file
systemctl daemon-reload

# Copy our JIRA configs over and fix permissions
mv /tmp/cots-mods-jira/jira-config.properties /var/atlassian/application-data/jira/
chown jira /var/atlassian/application-data/jira/jira-config.properties

# If we've not been given a url, don't setup server.xml
if [ ! -z ${JIRAUrl} ]; then
    # Comment out the default Connector, and uncomment the reverse-proxied HTTPS one
    patch /opt/atlassian/jira/conf/server.xml /tmp/cots-mods-jira/https--server.xml.patch

    # Add proxyName info
    sed -i "s/proxyName=\"<subdomain>.<domain>.com\"/proxyName=\"${JIRAUrl}\"/" /opt/atlassian/jira/conf/server.xml
fi

# Setup logging to be logrotate-friendly
cat /tmp/cots-mods-jira/logging.properties.suffix >> /opt/atlassian/jira/conf/logging.properties
patch /opt/atlassian/jira/conf/server.xml /tmp/cots-mods-jira/access-log--server.xml.patch
mv /tmp/cots-mods-jira/jira.logrotate /etc/logrotate.d/jira.conf

# Patch setenv.sh
patch /opt/atlassian/jira/bin/setenv.sh /tmp/cots-mods-jira/setenv.sh.patch

# Update email header to truncate quoted text from email replies
# see: https://confluence.atlassian.com/jirakb/remove-previous-content-from-incoming-email-from-jira-server-in-microsoft-outlook-223218415.html
patch /opt/atlassian/jira/atlassian-jira/WEB-INF/classes/templates/email/html/includes/header.vm /tmp/cots-mods-jira/header.vm.patch

# Get RDS root cert for TLS connection
wget https://s3.amazonaws.com/rds-downloads/rds-ca-2019-root.pem \
        -O /var/atlassian/application-data/jira/rds-ca-2019-root.pem

# Do a couple of things differently based on the environment
if [ "${Environment}" == "prod" ]
then
  # Enable JIRA service at boot-time
  systemctl enable jira
else
  # Turn off email notifications on non-prod
  sed -i 's/#DISABLE_NOTIFICATIONS=/DISABLE_NOTIFICATIONS=/' /opt/atlassian/jira/bin/setenv.sh

  # Delay JIRA startup when the EC2 is booting up (see comment in jira.timer for more details)
  mv /tmp/cots-mods-jira/jira.timer /etc/systemd/system/jira.timer

  # Enable JIRA service at boot-time via timer
  systemctl enable jira.timer
fi

# Start JIRA for this current boot
systemctl start jira

# Cleanup
rm -r /tmp/cots-mods-jira /tmp/installer.bin /tmp/pkg.zip
