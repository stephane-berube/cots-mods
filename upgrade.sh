#!/bin/bash -xe

if [[ $# -lt 1 ]] ; then
    echo "Usage: $0 <archiveUrl>"
    echo ""
    echo "Example: $0 'https://example.org/package.tar.gz' dev crowd.dev.example.org"
    exit 1
fi

CrowdArchiveUrl=$1

# Get and extract Crowd archive
wget "${CrowdArchiveUrl}" -O /tmp/crowd.tar.gz

# Delete old directory if it exists
if [ -d /tmp/crowd ]; then
    rm -r /tmp/crowd
fi

# Create directory to extract archive
mkdir -p /tmp/crowd
tar -xf /tmp/crowd.tar.gz -C /tmp/crowd/ 

# Figure out the folder name atlassian gave this release
new_install_dir=$(find /tmp/crowd/* -maxdepth 0 -type d)

# Set crowd home directory
echo 'crowd.home=/var/atlassian/application-data/crowd' >> "${new_install_dir}"/crowd-webapp/WEB-INF/classes/crowd-init.properties

# Setup logging to be logrotate-friendly
cat /tmp/cots-mods-crowd/logging.properties.suffix >> "${new_install_dir}"/apache-tomcat/conf/logging.properties

# Add the custom banner on the login page
patch "${new_install_dir}"/crowd-webapp/console/login.jsp /tmp/cots-mods-crowd/login.jsp.patch

# Stop crowd
systemctl stop crowd

# Replace the current install with the new one
mv /opt/atlassian/crowd/ "/tmp/crowd-$(date +%Y-%m-%d)"
mv "${new_install_dir}" /opt/atlassian/crowd
chown -R crowd:crowd /opt/atlassian/crowd

# Start crowd
systemctl start crowd

# Cleanup
rm -r /tmp/crowd.tar.gz /tmp/crowd

# Delete reminder
echo "Don't forget to delete the old installation directory, moved to /tmp/crowd-$(date +%Y-%m-%d)"
