# Oasis
Will build a Splunk single site cluster using Docker with:

  - 1 License server
  - 1 Deployment server
  - 3 Search Heads
  - 1 Master node
  - 4 Indexing peers
  - 2 Universal forwarders
  - 1 Heavy forwarder

As this is an enterprise deployment a valid Splunk Enterprise license must be provided in the file "enterprise.lic".

Example applications are deployed using both the Deployment server for the Universal and Heavy forwarders, but also onto the Master node to distribute onto each individual Indexing peers.

Indexer discovery is enabled

The License server acts as Monitoring Console

!!! This is CPU intensive, with 4 CPU / 12GB RAM, I have unpredictable results. 6 CPU / 16GB RAM is fine

# To Do

Disable indexing on the master node and the monitoring console instance
Rolling restart of all SH allowing MC to monitor all SH instead of crude restart
Use maintenance mode before properly restarting peers
