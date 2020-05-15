#!/bin/bash -xe

# TODO: Detect environment automatically
#
#       We could do this by inspecting the subnet on which the current machine
#       is on, for example.

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <archiveUrl> <Environment> [JIRAUrl]"
    echo ""
    echo "Example: $0 'https://example.org/archive.tar.gz' prod"
    exit 1
fi

JIRAArchiveUrl=$1
Environment=$2

# Get and extract JIRA archive
wget "${JIRAArchiveUrl}" -O /tmp/jira.tar.gz

# Delete old directory if it exists
if [ -d /tmp/jira ]; then
    rm -r /tmp/jira
fi

# Create directory to extract archive
mkdir -p /tmp/jira
tar -xf /tmp/jira.tar.gz -C /tmp/jira/ 

# Figure out the folder name atlassian gave this release
new_install_dir=$(find /tmp/jira/* -maxdepth 0 -type d)

# If we've not been given a url, don't setup server.xml
if [ ! -z ${JIRAUrl} ]; then
    # Comment out the default Connector, and uncomment the reverse-proxied HTTPS one
    patch "${new_install_dir}"/conf/server.xml ./https--server.xml.patch

    # Add proxyName info
    sed -i "s/proxyName=\"<subdomain>.<domain>.com\"/proxyName=\"${JIRAUrl}\"/" "${new_install_dir}"/conf/server.xml
fi

# Setup logging to be logrotate-friendly
cat ./logging.properties.suffix >> "${new_install_dir}"/conf/logging.properties
patch "${new_install_dir}"/conf/server.xml ./access-log--server.xml.patch

# Patch setenv.sh
patch "${new_install_dir}"/bin/setenv.sh ./setenv.sh.patch

# If we're not on Prod, turn off email notifications
if [ "${Environment}" != "prod" ]
then
  sed -i 's/#DISABLE_NOTIFICATIONS=/DISABLE_NOTIFICATIONS=/' "${new_install_dir}"/bin/setenv.sh
fi

# Update email header to truncate quoted text from email replies
# see: https://confluence.atlassian.com/jirakb/remove-previous-content-from-incoming-email-from-jira-server-in-microsoft-outlook-223218415.html
patch "${new_install_dir}"/atlassian-jira/WEB-INF/classes/templates/email/html/includes/header.vm ./header.vm.patch

# Stop jira
systemctl stop jira

# Replace the current install with the new one
mv /opt/atlassian/jira/ /opt/atlassian/jira-$(date +%Y-%m-%d)
mv "${new_install_dir}" /opt/atlassian/jira
chown -R jira:jira jira

# Start jira
systemctl start jira

# Cleanup
rm -r /tmp/jira.tar.gz /tmp/jira
