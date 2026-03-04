#!/bin/bash -xe

if [[ $# -lt 1 ]] ; then
    echo "Usage: $0 <archiveUrl> <Environment> [crowdDomain] [crowdIntDomain]"
    echo ""
    echo "Example: $0 'https://example.org/package.tar.gz' dev crowd.dev.example.org crowd-int.dev.example.org"
    exit 1
fi

CrowdArchiveUrl=$1
# "Environment" currently not used, but here to be consistent with the other cots
Environment=$2
crowdDomain=$3
crowdIntDomain=$4

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
cat ./logging.properties.suffix >> "${new_install_dir}"/apache-tomcat/conf/logging.properties

# Add the custom banner on the login page
# patch "${new_install_dir}"/crowd-webapp/console/login.jsp ./login.jsp.patch

# Redirect homepage "setup" page to the login page
# See: https://confluence.atlassian.com/crowdkb/redirect-crowd-server-setup-page-to-crowd-webapp-login-page-839978419.html
cp "${new_install_dir}"/crowd-webapp/WEB-INF/lib/urlrewritefilter-5.1.3.jar "${new_install_dir}"/apache-tomcat/lib/
cp "${new_install_dir}"/crowd-webapp/WEB-INF/urlrewrite.xml "${new_install_dir}"/apache-tomcat/webapps/ROOT/WEB-INF
patch "${new_install_dir}"/apache-tomcat/webapps/ROOT/WEB-INF/urlrewrite.xml ./urlrewrite.xml.patch
patch "${new_install_dir}"/apache-tomcat/webapps/ROOT/WEB-INF/web.xml ./web.xml.patch

# Trust store
trust_store_dir="/var/atlassian/application-data/crowd/upmconfig/truststore"
mkdir -p "${trust_store_dir}"
wget --directory-prefix "${trust_store_dir}" https://confluence.atlassian.com/upm/files/1489470540/1489470538/1/1736436578459/atlassian_ca_bundle-v1.tar.gz 
tar -C "${trust_store_dir}" -xf "${trust_store_dir}/atlassian_ca_bundle-v1.tar.gz"
rm "${trust_store_dir}/atlassian_ca_bundle-v1.tar.gz"
sudo chown -R root:root "${trust_store_dir}"

# If we've been given a url, setup server.xml
if [ -n "${crowdDomain}" ]; then
    patch "${new_install_dir}"/apache-tomcat/conf/server.xml ./server.xml.patch
    sed -i "s/{{ ised-crowd-domain }}/${crowdDomain}/g" "${new_install_dir}"/apache-tomcat/conf/server.xml
fi

# If we've been given a "int" url, add additional connector to server.xml
if [ -n "${crowdIntDomain}" ]; then
    sed -i '/<Service name="Catalina">/{
        s/<Service name="Catalina">//g
        r server.xml-crowd-int
    }' "${new_install_dir}"/apache-tomcat/conf/server.xml

    sed -i "s/{{ ised-crowd-int-domain }}/${crowdIntDomain}/g" "${new_install_dir}"/apache-tomcat/conf/server.xml
fi

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
