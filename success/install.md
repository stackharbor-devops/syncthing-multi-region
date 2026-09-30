Your distributed storage cluster **${settings.clusterName}** is ready.

- Region (primary): ${globals.sfsRegion}
- Cluster id: ${globals.sfsClusterId}
- Control plane (private network): ${globals.sfsCpUrl}

Manage it from the **Storage Cluster** add-on on the Storage layer: Status, Rebalance,
Heal, Backup Now, Add Region, Remove Node and **Open Advanced Management** (single sign-on,
no permanent password).

Mount the storage on an application layer with the **Storage Mount** add-on
(addons/mount.jps): pick this environment as the storage region and a mount path.
