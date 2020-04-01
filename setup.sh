#!/bin/bash -xe

if [[ $# -lt 3 ]] ; then
    echo "Usage: setup.sh <installerUrl> <dataVolume> <appVolume>"
    echo ""
    echo "Example: setup.sh 'https://example.org/installer.bin' /dev/sda /dev/sdb dev"
    exit 1
fi

BitbucketInstallerUrl=$1
EC2DataVolumeMount=$2
EC2AppVolumeMount=$3

# Create directories
mkdir -p /opt/atlassian/bitbucket /var/atlassian/application-data/bitbucket

# Wait until the volume shows up
while [ ! -e ${EC2DataVolumeMount} ]; do echo Waiting for EBS Data volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2DataVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2DataVolumeMount}    /var/atlassian/application-data/bitbucket xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Wait until the volume shows up
while [ ! -e ${EC2AppVolumeMount} ]; do echo Waiting for EBS App volume to attach; sleep 5; done

# Create filesystem
mkfs -t xfs "${EC2AppVolumeMount}"

# Add an entry to fstab to mount volume during boot
echo "${EC2AppVolumeMount}     /opt/atlassian/bitbucket                xfs    defaults,noatime,nofail    0    2" >> /etc/fstab

# Mount the volumes on current boot
mount -a

# Get and run Bitbucket installer
wget "${BitbucketInstallerUrl}" -O /tmp/installer.bin
chmod u+x /tmp/installer.bin
yes '' | /tmp/installer.bin

# Stop the running Bitbucket instance
service atlbitbucket stop

# Disable the old Bitbucket boot-time startup
systemctl disable atlbitbucket

# Copy our systemd unit file
mv /tmp/cots-mods/atlbitbucket.service /etc/systemd/system/atlbitbucket.service

# Bitbucket uses its version number as a directory name when
# it installs. Figure out what the directory name is and add
# a 'install-directory' symlink pointing to it. The symlink is
# used by the systemd unit file (atlbitbucket.service)
dir=$(find * -maxdepth 0 -type d | sort -r | head -n 1)
ln -s "${!dir}" install-directory

# Refresh systemd daemons since we've added a new unit file
# start Bitbucket and enable startup at boot-time
systemctl daemon-reload
systemctl enable atlbitbucket --now

# Cleanup
rm -f /tmp/cots-mods /tmp/installer.bin /tmp/pkg.zip
