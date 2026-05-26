#!/bin/bash -eu

# TODOS:
# * /var/atlassian/application-data/bitbucket/shared/bitbucket.properties needs the following:
#     server.proxy-port=443server.scheme=https
#     server.secure=true
#     server.require-ssl=true
#     feature.public.access=false
# * The following line in "/opt/atlassian/bitbucket/bin/set-jre-home.sh" needs to be commented out:
# JRE_HOME="/opt/atlassian/bitbucket/9.4.8/jre"

if [[ $# -lt 3 ]] ; then
    echo "Usage: $0 <installerUrl> <dataVolume> <appVolume> Environment [BitbucketUrl]"
    echo ""
    echo "Example: $0 'https://example.org/installer.bin' /dev/sda /dev/sdb dev"
    exit 1
fi

BitbucketInstallerUrl=$1
EC2DataVolumeMount=$2
EC2AppVolumeMount=$3
Environment=$4
BitbucketUrl=$5

# Create directories
mkdir -p /opt/atlassian/bitbucket /var/atlassian/application-data/bitbucket

# Wait until the volume shows up
while [ ! -e "${EC2DataVolumeMount}" ]; do echo Waiting for EBS Data volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2DataVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2DataVolumeMount}    /var/atlassian/application-data/bitbucket xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Wait until the volume shows up
while [ ! -e "${EC2AppVolumeMount}" ]; do echo Waiting for EBS App volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2AppVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2AppVolumeMount}     /opt/atlassian/                xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Mount the volumes on current boot
mount -a

# Install deps
yum install -y fontconfig git java-17-amazon-corretto-headless

# Get and run Bitbucket installer
wget "${BitbucketInstallerUrl}" -O /tmp/installer.bin
chmod u+x /tmp/installer.bin
yes '' | /tmp/installer.bin

# Stop the running Bitbucket instance
service atlbitbucket stop

# Disable the old Bitbucket boot-time startup
systemctl disable atlbitbucket

# Copy our systemd unit file
mv /tmp/cots-mods-bitbucket/atlbitbucket.service /etc/systemd/system/atlbitbucket.service

# Refresh systemd daemons since we've added a new unit file
systemctl daemon-reload

# Get RDS root cert for TLS connection
wget https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
        -O /var/atlassian/application-data/bitbucket/global-bundle.pem

# Trust store
trust_store_dir="/var/atlassian/application-data/bitbucket/upmconfig/truststore"
mkdir -p "${trust_store_dir}"
wget --directory-prefix "${trust_store_dir}" https://confluence.atlassian.com/upm/files/1489470540/1489470538/1/1736436578459/atlassian_ca_bundle-v1.tar.gz
tar -C "${trust_store_dir}" -xf "${trust_store_dir}/atlassian_ca_bundle-v1.tar.gz"
rm "${trust_store_dir}/atlassian_ca_bundle-v1.tar.gz"
chmod 644 "${trust_store_dir}/"*
chown -R root:root "${trust_store_dir}"

# Bitbucket uses its version number as a directory name when
# it installs. Figure out what the directory name is rename it to 'bitbucket'
# This folder is referenced by the systemd unit file (atlbitbucket.service)
dir=$(find /opt/atlassian/bitbucket/* -maxdepth 0 -type d | sort -r | head -n 1)

shopt -s dotglob # move dotfiles too
mv "${dir}"/* /opt/atlassian/bitbucket/
rmdir "${dir}"

# If a url was provided, add it to the config file
if [ -n "${BitbucketUrl}" ]
then
  echo "server.proxy-name=${BitbucketUrl}" >> /var/atlassian/application-data/bitbucket/shared/bitbucket.properties
fi

echo "server.proxy-port=443
server.scheme=https
server.secure=true
server.require-ssl=true
feature.public.access=false" >> /var/atlassian/application-data/bitbucket/shared/bitbucket.properties

# Do a couple of things differently based on the environment
if [ "${Environment}" == "prod" ]; then
  # Enable Bitbucket service at boot-time
  systemctl enable atlbitbucket
else
  # Delay Bitbucket startup when the EC2 is booting up (see comment in atlbitbucket.timer for more details)
  mv /tmp/cots-mods-bitbucket/atlbitbucket.timer /etc/systemd/system/atlbitbucket.timer

  # Enable JIRA service at boot-time via timer
  systemctl enable atlbitbucket.timer
fi

# Start Bitbucket for this current boot
systemctl start atlbitbucket

# Cleanup
rm -f /tmp/cots-mods-bitbucket /tmp/installer.bin /tmp/pkg.zip

