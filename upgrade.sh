#!/bin/bash -xe

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <archiveUrl>"
    echo ""
    echo "Example: $0 'https://example.org/archive.tar.gz'"
    exit 1
fi

BitbucketArchiveUrl=$1

# Get and extract Bitbucket archive
wget "${BitbucketArchiveUrl}" -O /tmp/bitbucket.tar.gz

# Delete old directory if it exists
if [ -d /tmp/bitbucket ]; then
    rm -r /tmp/bitbucket
fi

# Create directory to extract archive
mkdir -p /tmp/bitbucket
tar -xf /tmp/bitbucket.tar.gz -C /tmp/bitbucket/

# Figure out the folder name atlassian gave this release
new_install_dir=$(find /tmp/bitbucket/* -maxdepth 0 -type d)

# Stop Bitbucket
systemctl stop atlbitbucket

# Replace the current install with the new one
mv /opt/atlassian/bitbucket/ "/tmp/bitbucket-$(date +%Y-%m-%d)"
mv "${new_install_dir}" /opt/atlassian/bitbucket

chown -R atlbitbucket:atlbitbucket /opt/atlassian/bitbucket

# Start bitbucket
systemctl start altbitbucket

# Cleanup
rm -r /tmp/bitbucket.tar.gz /tmp/bitbucket

# Delete reminder
echo "Don't forget to delete the old installation directory, moved to /tmp/bitbucket-$(date +%Y-%m-%d)"
