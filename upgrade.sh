#!/bin/bash -xe

# TODO: Detect environment automatically
#
#       We could do this by inspecting the subnet on which the current machine
#       is on, for example.

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <archiveUrl> <Environment> [ConfluenceUrl]"
    echo ""
    echo "Example: $0 'https://example.org/archive.tar.gz' prod"
    exit 1
fi

ConfluenceArchiveUrl=$1
Environment=$2
ConfluenceUrl=$3

# Get and extract Confluence archive
wget "${ConfluenceArchiveUrl}" -O /tmp/confluence.tar.gz

# Delete old directory if it exists
if [ -d /tmp/confluence ]; then
    rm -r /tmp/confluence
fi

# Create directory to extract archive
mkdir -p /tmp/confluence
tar -xf /tmp/confluence.tar.gz -C /tmp/confluence/

# Figure out the folder name atlassian gave this release
new_install_dir=$(find /tmp/confluence/* -maxdepth 0 -type d)

# If we've not been given a url, don't setup server.xml
if [ -n "${ConfluenceUrl}" ]; then
    # Comment out the default Connector, and uncomment the reverse-proxied HTTPS one
    patch "${new_install_dir}"/conf/server.xml ./server.xml.patch

    # Add proxyName info
    sed -i "s/proxyName=\"<subdomain>.<domain>.com\"/proxyName=\"${ConfluenceUrl}\"/" "${new_install_dir}"/conf/server.xml
fi

# Update the location of the Confluence home directory
sed -i "s%# confluence.home=c:/confluence/data%confluence.home = /var/atlassian/application-data/confluence%" \
    "${new_install_dir}"/confluence/WEB-INF/classes/confluence-init.properties

# Remove default Xms, Xmx values
sed -i '/CATALINA_OPTS="-Xms1024m -Xmx1024/d' "${new_install_dir}"/bin/setenv.sh
# Append our customizations (which include new values for Xms and Xmx)
cat ./setenv.sh.suffix >> "${new_install_dir}"/bin/setenv.sh

# Stop confluence
systemctl stop confluence

# Replace the current install with the new one
mv /opt/atlassian/confluence/ "/tmp/confluence-$(date +%Y-%m-%d)"
mv "${new_install_dir}" /opt/atlassian/confluence

# Start confluence
systemctl start confluence

# Cleanup
rm -r /tmp/confluence.tar.gz /tmp/confluence

# Delete reminder
echo "Don't forget to delete the old installation directory, moved to /tmp/confluence-$(date +%Y-%m-%d)"
