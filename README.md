# Deployment

## Add a network

- [ ] Create a folder with the name of the network.
- [ ] In the folder create a **config** file reflecting the network topology and deployment parameters. _(To make it simple, you may copy config file form localnet and only change the deployment parameters like server IP address, ssh user name and remote deployment path, but keep the netwrok topology.)_

## Build necessary binary tools and update the paths in the config file

- oasis-node
- hela-evm.orc
- oasis-web3-gateway
- hela

To build all binaries:
```
./builder compile
```
To build individual binaries (e.g.: oasis-web3-gateway and cli):
```
./builder compile -- ../oasis-web3-gateway/ ../cli/
```

**Note:** the build system should have similar libc runtime as the remote deployment environment. e.g.: hela-evm.orc built in Ubuntu 20.04 cannot be run in Ubuntu 18.04, but can be run in Ubuntu 22.04.

## Setup auto ssh login to remote system

The ssh user specified by **DEPLOY_USER** of config file should be able to login to the remote system without password. This should be also done if local develop system is same as remote deployment system. 

## Install necessary tools

Tools **rsync**, **jq**, **yq**, **unzip** are required for the hela script to run.

yq is installed by pip (re-login might be required after install):
```
pip3 install yq
```
Other tools can be installed by the Linux package management system.

## Switch to the network being deployed

```
./builder --network={network name}
```
**Note:** After switch, further commands will be run on the switched network until switching to another network.

## Generate files for each element of the network

```
./builder generate
```
This command will create directory for each network element, and generate compulsory files inside each directory. 

## Deploy the network to remote side

```
./builder deploy
```
This command will deploy necessary files to remote systems. And also create and start systemd service for each node need to be running.

## Setup CLI in the client nodes
```
./builder setup
```
This command will setup cli network and runtime in all the client nodes. To add an entity (entity-51) to the wallet of cli for individual client node (client-01):
```
./builder setup client-01 --entity=entity-51
```

## Test the network

```
./builder entity
./builder status
```
This two commands will show the network pre-registered accounts information and nodes status. 

## Re-deploy the network

```
./builder undeploy
./builder deploy
```
or
```
./builder undeploy
./builder clean
./builder generate
./builder deploy
```
if need to generate those compulsory files again. 

## Restart a single node
e.g.: restart validator-01 node
```
./builder stop validator-01
./builder start validator-01
```
