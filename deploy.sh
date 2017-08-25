#!/bin/bash

# Helper function to avoid fixed sleep time waiting for a given container to become available
wait_for_splunk_container ()
{
  port=$(docker port $1 8000)
  until $(curl --output /dev/null --silent --head --fail http://localhost:${port##*:});
  do
    printf '.'
    sleep 5
  done
  printf "\n"
}

#
# This is a Splunk Enterprise deployment.
# A valid license file must be present in ths same directory as this script
# Without a valid license, enterprise features will be disabled (replication, ...)
#
LICENSE_FILE="enterprise.lic"

if [ ! -f $LICENSE_FILE ]
then
    echo "Splunk license file $LICENSE_FILE not found."
    echo "Exiting."
    exit 1
fi

#
# Define administrative user for remote management purposes
# This user will be added to all instances in order to allow proper cluster management without interfering with security policies
# --env SPLUNK_CMDx="add user $SPLUNK_ADMIN -password $SPLUNK_ADMIN_PASSWORD -role admin -auth admin:changeme"
#

SPLUNK_ADMIN="admin2"
SPLUNK_ADMIN_PASSWORD=$(openssl rand -hex 12)
echo ">Management user: $SPLUNK_ADMIN/$SPLUNK_ADMIN_PASSWORD"

#
# Define Indexing Cluster Search Factor (SF) Replication factor (RF) and number of Search Peers (SP)
#

SF=1
RF=$(( SF + 1))
SP=$(( RF + 1))

IX_CLUSTER_LABEL="OASIS"
IX_CLUSTER_KEY=$(openssl rand -hex 12)

#
# Define Search Head Cluster parameters, number of members (SH), Label and Secret
#

SH=3
SH_CLUSTER_LABEL="SH_$IX_CLUSTER"
SH_CLUSTER_KEY=$(openssl rand -hex 12)

#
# Define number of Universal Forwarders (UF)
#

UF=1

#
# --- Cleaning old Stuff
#

echo "Cleaning old stuff"
docker rm -vf $(docker ps -aq)
docker network rm splunk

#
# --- Create Network
#

echo "Creating docker network, so all containers will see each other"
docker network create splunk

#
# ---  License server
#

echo "Starting License server"
docker run -d --net splunk \
    --hostname splunklicenseserver \
    --name splunklicenseserver \
    --publish 8000 \
    --env SPLUNK_START_ARGS=--accept-license \
    --env SPLUNK_CMD="add user $SPLUNK_ADMIN -password $SPLUNK_ADMIN_PASSWORD -role admin -auth admin:changeme" \
    splunk/splunk

wait_for_splunk_container splunklicenseserver
echo "Add License"
docker cp ./$LICENSE_FILE splunklicenseserver:/tmp/enterprise.lic
docker exec splunklicenseserver entrypoint.sh splunk add licenses /tmp/enterprise.lic -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD
echo "Disable Indexing on License master"
docker cp ./search_head_outputs.conf splunklicenseserver:/opt/splunk/etc/system/local/
docker exec splunklicenseserver bash -c "cd etc/system/local && cat search_head_outputs.conf >> outputs.conf"
echo "Restarting License server"
docker exec splunklicenseserver entrypoint.sh splunk restart

#
# --- Create Indexing tier
#
# --- Create Indexer Cluster Master
#

echo "Starting Splunk Master"
docker run -d --net splunk \
    --hostname splunkmaster \
    --name splunkmaster \
    --publish 8000 \
    --env SPLUNK_START_ARGS=--accept-license \
    --env SPLUNK_CMD="add user $SPLUNK_ADMIN -password $SPLUNK_ADMIN_PASSWORD -role admin -auth admin:changeme" \
    --env SPLUNK_CMD_1="edit cluster-config -mode master -replication_factor $RF -search_factor $SF -secret $IX_CLUSTER_KEY -cluster_label $IX_CLUSTER_LABEL -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD" \
		--env SPLUNK_CMD_2="edit licenser-localslave -master_uri https://splunklicenseserver:8089 -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD" \
    splunk/splunk

wait_for_splunk_container splunkmaster
echo "Enabling Indexer discovery on Master"
docker cp ./master_server.conf splunkmaster:/opt/splunk/etc/system/local/
docker exec splunkmaster bash -c "cd etc/system/local && cat master_server.conf >> server.conf"
echo "Disable Indexing on Master"
docker cp ./search_head_outputs.conf splunkmaster:/opt/splunk/etc/system/local/
docker exec splunkmaster bash -c "cd etc/system/local && cat search_head_outputs.conf >> outputs.conf"

# Apply changes to cluster role and create master-apps directory
echo "Restarting Master"
docker exec splunkmaster entrypoint.sh splunk restart

wait_for_splunk_container splunkmaster
echo "Upload Test app"
cat apps/TA-oasis-test.tgz | docker exec -i splunkmaster tar Cxzf /opt/splunk/etc/master-apps/ -
echo "Fixing permissions"
docker exec splunkmaster chown -R splunk:splunk /opt/splunk/etc/master-apps/
echo "Applying Bundle"
docker exec splunkmaster entrypoint.sh splunk apply cluster-bundle --answer-yes -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD

#
# --- Create Search Heads
#

wait_for_splunk_container splunkmaster # Needed to further build the cluster

SH_LIST="" # Will hold the SH cluster member list

for ((i = 1; i <= $SH; i++)); do
  echo "Starting Search Head splunksh$i"
  docker run -d --net splunk \
      --hostname splunksh$i \
      --name splunksh$i \
      --publish 8000 \
      --env SPLUNK_START_ARGS=--accept-license \
      --env SPLUNK_CMD="add user $SPLUNK_ADMIN -password $SPLUNK_ADMIN_PASSWORD -role admin -auth admin:changeme" \
      --env SPLUNK_CMD_1="edit cluster-config -mode searchhead -master_uri https://splunkmaster:8089 -secret $IX_CLUSTER_KEY -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD" \
  		--env SPLUNK_CMD_2="edit licenser-localslave -master_uri https://splunklicenseserver:8089 -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD" \
      splunk/splunk
  SH_LIST+=",https://splunksh$i:8089"
done

for ((i = 1; i <= $SH; i++)); do
  wait_for_splunk_container splunksh$i
  docker ps -a
  echo "Disable Indexing on splunksh$i"
  docker cp ./search_head_outputs.conf splunksh$i:/opt/splunk/etc/system/local/
  docker exec splunksh$i bash -c "cd etc/system/local && cat search_head_outputs.conf >> outputs.conf"
  docker ps -a
  echo "Preparing SH cluster membership"
  docker exec splunksh$i entrypoint.sh splunk init shcluster-config -mgmt_uri https://splunksh$i:8089 -replication_port 9200 -secret $SH_CLUSTER_KEY -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD
  docker ps -a
  echo "Restarting splunksh$i"
  docker exec splunksh$i entrypoint.sh splunk restart
done

#
# Bootstrap SH cluster from splunksh1 using member list SH_LIST build during initialization getting rid of initial ","
#

wait_for_splunk_container splunksh1 # Needed to build the cluster
echo "Bootstrapping ..."
docker exec splunksh1 entrypoint.sh splunk bootstrap shcluster-captain -servers_list ${SH_LIST#?} -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD
wait_for_splunk_container splunksh1
docker exec splunksh1 entrypoint.sh splunk edit shcluster-config -shcluster_label $SH_CLUSTER_LABEL -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD
wait_for_splunk_container splunksh1
echo "Restarting splunksh1 ..."
docker exec splunksh1 entrypoint.sh splunk restart

#
# --- Create Search Peers (indexing nodes)
#

wait_for_splunk_container splunkmaster # Needed to further build the cluster
for ((i = 1; i <= $SP; i++)); do
		echo "Starting splunkpeer$i"
		docker run -d --net splunk \
				--hostname splunkpeer$i \
				--name splunkpeer$i \
				--publish 8000 \
				--env SPLUNK_START_ARGS=--accept-license \
				--env SPLUNK_ENABLE_LISTEN=9997 \
        --env SPLUNK_CMD="add user $SPLUNK_ADMIN -password $SPLUNK_ADMIN_PASSWORD -role admin -auth admin:changeme" \
				--env SPLUNK_CMD_1="edit cluster-config -mode slave -master_uri https://splunkmaster:8089 -replication_port 9100 -secret $IX_CLUSTER_KEY -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD" \
				--env SPLUNK_CMD_2="edit licenser-localslave -master_uri https://splunklicenseserver:8089 -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD" \
				splunk/splunk
done

#
# Restart all Peers to apply config changes
#

for ((i = 1; i <= $SP; i++)); do
  wait_for_splunk_container splunkpeer$i
  echo "Restarting splunkpeer$i"
  docker exec splunkpeer$i entrypoint.sh splunk restart
done

#
# ---- Forwarding tier
#
# --- Create Deployment Server
#

echo "Starting Deployment server for forwarders"
docker run -d --net splunk \
    --hostname splunkdeploymentserver \
    --name splunkdeploymentserver \
    --publish 8000 \
    --env SPLUNK_START_ARGS=--accept-license \
    --env SPLUNK_ENABLE_DEPLOY_SERVER=true \
    --env SPLUNK_CMD="add user $SPLUNK_ADMIN -password $SPLUNK_ADMIN_PASSWORD -role admin -auth admin:changeme" \
    splunk/splunk

wait_for_splunk_container splunkdeploymentserver
echo "Disable Indexing on Deployment server"
docker cp ./search_head_outputs.conf splunkdeploymentserver:/opt/splunk/etc/system/local/
docker exec splunkdeploymentserver bash -c "cd etc/system/local && cat search_head_outputs.conf >> outputs.conf"

echo "Upload Apps"
for apps in apps/*.tgz
do
	cat "$apps" | docker exec -i splunkdeploymentserver tar Cxzf /opt/splunk/etc/deployment-apps/ -
done

echo "Fixing permissions"
docker exec splunkdeploymentserver chown -R splunk:splunk /opt/splunk/etc/deployment-apps/

echo "Create servereclass.conf"
docker cp ./serverclass.conf splunkdeploymentserver:/opt/splunk/etc/system/local/serverclass.conf

echo "Restarting Deployment server"
docker exec splunkdeploymentserver entrypoint.sh splunk restart

#
# --- Create Universal and Heavy forwarders
#

for ((i = 1; i <= $UF; i++)); do
  echo "Starting splunkuf$i"
  docker run -d --net splunk \
      --name splunkuf$i \
      --hostname splunkuf$i \
      --env SPLUNK_START_ARGS=--accept-license \
      --env SPLUNK_DEPLOYMENT_SERVER='splunkdeploymentserver:8089' \
      --env SPLUNK_CMD="add user $SPLUNK_ADMIN -password $SPLUNK_ADMIN_PASSWORD -role admin -auth admin:changeme" \
      splunk/universalforwarder
done

sleep 30 # Container has no public port
for ((i = 1; i <= $UF; i++)); do
  echo "Enabling splunkuf$i for Indexer discovery"
  docker cp ./forwarder_outputs.conf splunkuf$i:/opt/splunk/etc/system/local/outputs.conf
  echo "Restarting splunkuf$i"
  docker exec splunkuf$i entrypoint.sh splunk restart
done

#
# Generate traffic with
#   while true; do echo "$(date) Hello" >> /var/log/dpkg.log; sleep 10; done

#
# --- Heavy Forwarder
#

echo "Starting Heavy Forwarder"
docker run -d --net splunk \
    --hostname splunkhf1 \
    --name splunkhf1 \
    --publish 8000 \
    --env SPLUNK_START_ARGS=--accept-license \
    --env SPLUNK_DEPLOYMENT_SERVER='splunkdeploymentserver:8089' \
    --env SPLUNK_CMD="add user $SPLUNK_ADMIN -password $SPLUNK_ADMIN_PASSWORD -role admin -auth admin:changeme" \
    --env SPLUNK_CMD_1="enable app SplunkForwarder -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD" \
		--env SPLUNK_CMD_2="edit licenser-localslave -master_uri https://splunklicenseserver:8089 -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD" \
    splunk/splunk

wait_for_splunk_container splunkhf1
echo "Enabling Heavy Forwarder for Indexer discovery"
docker cp ./forwarder_outputs.conf splunkhf1:/opt/splunk/etc/system/local/outputs.conf
echo "Restarting Heavy Forwarder"
docker exec splunkhf1 entrypoint.sh splunk restart

#
# Configure Licence Master to host the Monitoring Console
#

# Add cluster components
docker exec splunklicenseserver entrypoint.sh splunk add search-server splunkmaster:8089 -remoteUsername $SPLUNK_ADMIN -remotePassword $SPLUNK_ADMIN_PASSWORD -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD
for ((i = 1; i <= $SP; i++)); do
  docker exec splunklicenseserver entrypoint.sh  splunk add search-server splunksh$i:8089 -remoteUsername $SPLUNK_ADMIN -remotePassword $SPLUNK_ADMIN_PASSWORD -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD
done

docker exec splunklicenseserver entrypoint.sh splunk edit cluster-config -mode searchhead -master_uri https://splunkmaster:8089 -secret $IX_CLUSTER_KEY -auth $SPLUNK_ADMIN:$SPLUNK_ADMIN_PASSWORD
docker exec splunklicenseserver entrypoint.sh splunk restart
