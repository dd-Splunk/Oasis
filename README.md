# Oasis
Will build a Splunk single site cluster using Docker with:

  - 1 License server
  - 1 Deployment server
  - 3 Search Heads
  - 1 Master node
  - x Indexing peers depending on the Search Factor ($SF) and Replication Factor ($RF)
  - $UF Universal forwarders
  - $HF Heavy forwarder

As this is an enterprise deployment a valid Splunk Enterprise license must be provided in the file "enterprise.lic".

Example applications are deployed using both the Deployment server for the Universal and Heavy forwarders, but also onto the Master node to distribute onto each individual Indexing peers.

Indexer discovery is enabled

The License server acts as Monitoring Console

!!! This is CPU intensive, with 2 Cores - 4 vCPU / 12GB RAM, I have unpredictable results. 3 Cores - 6 vCPU / 16GB RAM is fine

# To Do

Disable indexing on the master node and the monitoring console instance

Use maintenance mode before properly restarting peers
