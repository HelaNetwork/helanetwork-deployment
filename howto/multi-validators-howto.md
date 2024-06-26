## Environments Setup
### Develop Environment
Refer to the link below for the develop environment setup:

[https://docs.oasis.io/core/development-setup/prerequisites](https://docs.oasis.io/core/development-setup/prerequisites)

### Deploy Environment
This environment is for the initial setup to start the network. Later on, more nodes will join the network dynamically.

#### Hardware Requirements
Please refer to link below for hardware requirements of multiple classes of node:

[https://docs.oasis.io/node/run-your-node/prerequisites/hardware-recommendations](https://docs.oasis.io/node/run-your-node/prerequisites/hardware-recommendations)

#### Operating System
Only 64-bit Linux is supported. Ubuntu 18.04 or higher version are recommended.

#### IP Addresses, Ports and Firewall
The node IP addresses and ports expoosed by firewall decide where the new nodes and clients can connect from.

Set firewall rules properly to make sure all nodes connecting to other nodes by same network interface and remember IP address of the interface.

## Plan entities, runtimes, seed nodes, validator nodes, compute nodes and client nodes

- Decide number of seed nodes

- Decide entities, validator nodes and runtimes in genesis.json file so that they can become pre-registered when network started.

- Decide entities under which validator nodes or compute nodes are registered.

- Decide for each runtime how many compute and client nodes are regustered and running 

- Make sure one entity is in the plan for holding the total amount of supply tokens.

- Make sure one entity in the plan for runtime if governance model is entity. 

- Naming entity and node like: entity-01, validator-01, seed-01, ...

## Build required executable files: oasis-node, oasis cli, runtime orc (Emerald only) and oasis-web3-gateway

* In oasis-core repository run:
```
OASIS_UNSAFE_SKIP_AVR_VERIFY="1" \
OASIS_UNSAFE_SKIP_KM_POLICY="1" \
OASIS_UNSAFE_ALLOW_DEBUG_ENCLAVES="1" \
OASIS_BADGER_NO_JEMALLOC="1" \
make
```
This command will generate **oasis-node** executable binary without SGX supporting under sub-direcotry: go/oasis-node/.

* In oasis cli repository run:
```
make
```
This will generate **oasis** executable file under the root directory of the repository.

* Install runtime bundle generating tool orc:
```
go install github.com/oasisprotocol/oasis-sdk/tools/orc@latest
```

* In oasis emerald-paratime repository run:
```
cargo build
orc init target/debug/emerald-paratime
```
The Emerald bundle file **emerald-paratime.orc** will be generated in repository root directory.

* In oasis oasis-web3-gateway repository run:
```
make build
```
This will generate executable file **oasis-web3-gateway**. 

## Files initializing for entities, nodes, runtime and web3 gateway

### Create fold for entities, nodes, runtime and web3 gateway by its name.

Create a deployment folder, then under the deployment folder create folders for all entities and nodes, e.g.:
```
mkdir oasis-deploy
cd oasis-deploy
mkdir seed-01
mkdir entity-01 entity-02
mkdir validator-01 validator-02
mkdir compute-01 compute-02 compute-03
mkdir client-01
mkdir runtime-emerald
mkdir w3-gateway-01
chmod 700 *
```
### Copy the binary files built to corresponding folders ###

```
 oasis-node           => oasis-deploy/
 oasis                => oasis-deploy/
 oasis-web3-gateway   => oasis-deploy/
 emerald-paratime.orc => oasis-deploy/runtime-emerald/
```

### Initialize entities
Go to each entity folder and run:
```
../oasis-node registry entity init
```
Get entity ID:
```
ENTITY_XX_ID=`jq -r .id entity.json`
```

### Initialize validator nodes
Go to each folder of validator nodes run (_Replace **{IP}** and **{PORT}** to the validator node exposed IP address and port_): 
```
../oasis-node registry node init \
  --node.entity_id $ENTITY_XX_ID \
  --node.consensus_address {IP}:{PORT} \
  --node.role validator
```

### Update entities with validator nodes
Go to the folder of entity with validators, update the entity descriptor by the validator nodes.
e.g.: Update validator-01 and validator-02 to the entity:
```
../oasis-node registry entity update \
  --entity.node.descriptor ../validator-01/node_genesis.json,../validator-02/node_genesis.json
```

### Initialize non-validator nodes
Go to folder of each seed node, sentry node, compute node and client node, run:
```
../oasis-node identity init --datadir .
```
For seed node, get tendermint ID:
```
SEED_TENDERMINT_ID=`../oasis-node identity tendermint show-node-address --datadir .`
```

### Update entities with compute nodes
Go to the folder of entity with compute nodes, update the entity descriptor by compute nodes.
e.g.: Update compute-01, compute-02 and compute-03 to the entity:
```
ids=
for n in compute-01 compute-02 compute-03 ; do
  id=`sed -n '/^[^-]/p' ../$n/identity_pub.pem`
  ids="$ids${ids:+,}$id"
done
../oasis-node registry entity update --entity.node.id $ids
```

## Generate Emerald Descriptor file ##
In runtime-emerald folder, create file:
<details><summary>runtime_genesis.json</summary>

```
{
  "v": 3,
  "id": "00000000000000000000000000000000000000000000000072c8215e60d5bca7",
  "entity_id": "$ENTITY_XX_ID",
  "genesis": {
    "state_root": "c672b8d1ef56ed28ab87c3622c5114069bdd3ad7b8f9737498d0c01ecef0967a",
    "round": 0
  },
  "kind": 1,
  "tee_hardware": 0,
  "executor": {
    "group_size": 2,
    "group_backup_size": 1,
    "allowed_stragglers": 0,
    "round_timeout": 20,
    "max_messages": 128
  },
  "txn_scheduler": {
    "batch_flush_timeout": 1000000000,
    "max_batch_size": 20,
    "max_batch_size_bytes": 1048576,
    "propose_batch_timeout": 2
  },
  "storage": {
    "checkpoint_interval": 0,
    "checkpoint_num_kept": 0,
    "checkpoint_chunk_size": 0
  },
  "admission_policy": {
    "any_node": {}
  },
  "staking": {
    "min_in_message_fee": "0"
  },
  "governance_model": "entity",
  "deployments": [
    {
      "version": {
        "major": 10
      },
      "valid_from": 0
    }
  ]
}
```
</details>

## Generate genesis.json

### Create a basic genesis.json without any entity and node
Under deployment folder create file:
<details><summary>genesis.json</summary>

```
{
  "height": 1,
  "genesis_time": "2023-01-20T00:55:11.680792185+08:00",
  "chain_id": "hela:oasis-core:testnet",
  "registry": {
    "params": {
      "debug_allow_unroutable_addresses": true,
      "debug_allow_test_runtimes": true,
      "gas_costs": {
        "deregister_entity": 1000,
        "prove_freshness": 1000,
        "register_entity": 1000,
        "register_node": 1000,
        "register_runtime": 1000,
        "runtime_epoch_maintenance": 1000,
        "unfreeze_node": 1000,
        "update_keymanager": 1000
      },
      "max_node_expiration": 5,
      "enable_runtime_governance_models": {
        "entity": true,
        "runtime": true
      },
      "tee_features": {
        "sgx": {
          "pcs": true,
          "signed_attestations": true,
          "max_attestation_age": 1200
        },
        "freshness_proofs": true
      }
    },
    "entities": [],
    "nodes": [],
    "runtimes": []
  },
  "roothash": {
    "params": {
      "gas_costs": {
        "compute_commit": 1000,
        "evidence": 1000,
        "proposer_timeout": 1000,
        "submit_msg": 1000
      },
      "max_runtime_messages": 128,
      "max_in_runtime_messages": 128,
      "max_evidence_age": 0
    }
  },
  "staking": {
    "params": {
      "thresholds": {
        "entity": "0",
        "node-compute": "0",
        "node-keymanager": "0",
        "node-validator": "0",
        "runtime-compute": "0",
        "runtime-keymanager": "0"
      },
      "debonding_interval": 1,
      "commission_schedule_rules": {},
      "min_delegation": "0",
      "min_transfer": "0",
      "min_transact_balance": "0",
      "max_allowances": 16,
      "fee_split_weight_propose": "0",
      "fee_split_weight_vote": "1",
      "fee_split_weight_next_propose": "0",
      "reward_factor_epoch_signed": "0",
      "reward_factor_block_proposed": "0"
    },
    "token_symbol": "HELA",
    "token_value_exponent": 9,
    "total_supply": "2000000000000000",
    "common_pool": "0",
    "last_block_fees": "0",
    "governance_deposits": "0",
    "ledger": {
      "__account__": {
        "general": {
          "balance": "1000000000000000"
        },
        "escrow": {
          "active": {
            "balance": "1000000000000000",
            "total_shares": "1"
          },
          "debonding": {
            "balance": "0",
            "total_shares": "0"
          },
          "commission_schedule": {},
          "stake_accumulator": {}
        }
      }
    },
    "delegations": {
      "__account__": {
        "__account__": {
          "shares": "1"
        }
      }
    }
  },
  "scheduler": {
    "params": {
      "min_validators": 1,
      "max_validators": 100,
      "max_validators_per_entity": 2,
      "reward_factor_epoch_election_any": "0"
    }
  },
  "beacon": {
    "base": 0,
    "params": {
      "backend": "insecure",
      "insecure_parameters": {
        "interval": 30
      }
    }
  },
  "governance": {
    "params": {
      "gas_costs": {
        "cast_vote": 1000,
        "submit_proposal": 1000
      },
      "min_proposal_deposit": "100",
      "voting_period": 100,
      "stake_threshold": 90,
      "upgrade_min_epoch_diff": 300,
      "upgrade_cancel_min_epoch_diff": 300,
      "enable_change_parameters_proposal": true
    }
  },
  "consensus": {
    "backend": "tendermint",
    "params": {
      "timeout_commit": 1000000000,
      "skip_timeout_commit": false,
      "empty_block_interval": 0,
      "max_tx_size": 32768,
      "max_block_size": 22020096,
      "max_block_gas": 0,
      "max_evidence_size": 1048576,
      "state_checkpoint_interval": 0,
      "state_checkpoint_chunk_size": 8388608,
      "gas_costs": {
        "tx_byte": 0
      }
    }
  },
  "halt_epoch": 18446744073709551615,
  "extra_data": null
}
```
</details>

### Set genesis_time

```
jq ".genesis_time=\"`date +%Y-%m-%dT%H:%M:%S.%N%:z`\"" genesis.json > genesis.tmp
mv genesis.tmp genesis.json
```

### Add Entities
Run command below to add each entity to genesis.json:
```
for e in entity-* ; do
  jq ".registry.entities += [`jq -c . $e/entity_genesis.json`]" genesis.json >genesis.tmp
  mv genesis.tmp genesis.json
done
```

### Add Validators
Run command below to add each validator node to genesis.json:
```
for n in validator-* ; do
  jq ".registry.nodes += [`jq -c . $n/node_genesis.json`]" genesis.json >genesis.tmp
  mv genesis.tmp genesis.json
done
```

### Add Runtimes
Run command below to add each validator node to genesis.json:
```
for n in runtime-* ; do
  jq ".registry.runtimes += [`jq -c . $n/runtime_genesis.json`]" genesis.json >genesis.tmp
  mv genesis.tmp genesis.json
done
```

### Set staking ledger account for holding total supply tokens

Set staking ledger account to genesis.json by commands below (_Replace **{ENTITY}** to the entity name for holding total supply tokens_)
```
ENTITY_ID=`jq -r .id {ENTITY}/entity.json`
ACCOUNT=`oasis-node stake pubkey2address --public_key $ENTITY_ID`
jq ".staking.ledger |= with_entries(.key = \"$ACCOUNT\") | 
    .staking.delegations |= with_entries(.key = \"$ACCOUNT\") |
    .staking.delegations.$ACCOUNT |= with_entries(.key = \"$ACCOUNT\")
" genesis.json >genesis.tmp
mv genesis.tmp genesis.json
```

## Generate nodes configuration files

### Create config file for seed nodes
Under each seed node folder, create config file (
_Replace **{IP}** and **{PORT}** to the seed node exposed IP address and port_):
<details><summary>config.yml</summary>

```
datadir: .

log:
  level: debug
  format: JSON
  file: ./node.log

debug:
  dont_blame_oasis: true
  allow_root: true
  allow_test_keys: true
  rlimit: 50000
  allow_debug_enclaves: true

genesis:
  file: ../genesis.json

consensus:
  tendermint:
    mode: seed
    core:
      listen_address: tcp://0.0.0.0:{PORT}
      external_address: tcp://{IP}:{PORT}
    debug:
      addr_book_lenient: true
      allow_duplicate_ip: true
    upgrade:
      stop_delay: 10s
```
</details>

### Create Config file for validator nodes

Under each validator node folder, create config file (
_Replace **{IP}** and **{PORT}** to the validator node exposed IP address and port; replace **{ENTITY}** to the entity name; replace **{SEED_IP}**, **{SEED_PORT}** to seed node IP address and port_):

<details><summary>config.yml</summary>

```
datadir: .

log:
  level:
    default: debug
    tendermint: warn
    tendermint/context: error
  format: JSON
  file: ./node.log

debug:
  dont_blame_oasis: true
  allow_root: true
  allow_test_keys: true
  rlimit: 50000
  crash:
    default: 0.000000
  allow_debug_enclaves: true

genesis:
  file: ../genesis.json

worker:
  registration:
    rotate_certs: 1
    entity: ../{ENTITY}/entity.json

consensus:
  validator: true

  tendermint:
    core:
      listen_address: tcp://0.0.0.0:{PORT}
      external_address: tcp://{IP}:{PORT}

    min_gas_price: 0
    submission:
      gas_price: 0
    abci:
      prune:
        strategy: none
    supplementarysanity:
      enabled: true
      interval: 1

    p2p:
      seed:
        - "${SEED_TENDERMINT_ID}@{SEED_IP}:{SEED_PORT}"
    debug:
      addr_book_lenient: true
      allow_duplicate_ip: true
    upgrade:
      stop_delay: 10s
```
</details>

### Create Config file for compute nodes

Under each compute node folder, create config file (
_Replace **{IP}** and **{PORT}** to the validator node exposed IP address and port; replace **{ENTITY}** to the entity name; replace **{SEED_IP}**, **{SEED_PORT}** to seed node IP address and port_):

<details><summary>config.yml</summary>

```
datadir: .

log:
  level:
    default: debug
    tendermint: warn
    tendermint/context: error
  format: JSON
  file: ./node.log

debug:
  dont_blame_oasis: true
  allow_root: true
  allow_test_keys: true
  rlimit: 50000
  crash:
    default: 0.000000
  allow_debug_enclaves: true

genesis:
  file: ../genesis.json

worker:
  registration:
    rotate_certs: 1
    entity: ../{ENTITY}/entity.json
  client:
    port: {CLIENT_PORT}
  p2p:
    port: {P2P_PORT}
  storage:
    backend: badger
    public_rpc:
      enabled: true
    checkpoint_sync:
      disabled: true
    checkpointer:
      enabled: true

runtime:
  mode: compute
  provisioner: unconfined
  sgx:
    loader: oasis-core-runtime-loader
  paths: ../${RUNTIME}/{RUNTIME_ORC}

grpc:
  log:
    debug: true

consensus:
  tendermint:
    core:
      listen_address: tcp://0.0.0.0:{PORT}
      external_address: tcp://{IP}:{PORT}
    min_gas_price: 0
    submission:
      gas_price: 0
    abci:
      prune:
        strategy: none
    p2p:
      seed:
        - "${SEED_TENDERMINT_ID}@{SEED_IP}:{SEED_PORT}"
    debug:
      addr_book_lenient: true
      allow_duplicate_ip: true
    upgrade:
      stop_delay: 10s
```
</details>

### Create Config file for client nodes

Under each compute node folder, create config file (
_Replace **{IP}** and **{PORT}** to the validator node exposed IP address and port; replace **{ENTITY}** to the entity name; replace **{SEED_IP}**, **{SEED_PORT}** to seed node IP address and port_):

<details><summary>config.yml</summary>

```
datadir: .

log:
  level:
    # Per-module log levels. Longest prefix match will be taken. Fallback to
    # "default", if no match.
    default: debug
    tendermint: warn
    tendermint/context: error
  format: JSON
  file: ./node.log

debug:
  dont_blame_oasis: true
  allow_root: true
  allow_test_keys: true
  rlimit: 50000
  crash:
    default: 0.000000
  allow_debug_enclaves: true

genesis:
  file: ../genesis.json

worker:
  p2p:
    port: {P2P_PORT}

runtime:
  mode: client-stateless
  provisioner: unconfined
  paths: ../{RUNTIME}/{RUNTIME_ORC}
  config:
    "{RUNTIME_ID}":
      allow_expensive_queries: true

grpc:
  log:
    debug: true

consensus:
  tendermint:
    core:
      listen_address: tcp://0.0.0.0:{PORT}
      external_address: tcp://{IP}:{PORT}
    abci:
      prune:
        strategy: none
    p2p:
      seed:
        - "${SEED_TENDERMINT_ID}@{SEED_IP}:{SEED_PORT}"
    debug:
      addr_book_lenient: true
      allow_duplicate_ip: true
    upgrade:
      stop_delay: 10s
```
</details>

### Create Config file for web3-gateway nodes

Under each web3 gateway folder, create config file (
_Replace **{RUNTIME_ID}** to Paratime ID; replace **{CLIENT}* to the client node name_):

<details><summary>config.yml</summary>

```
runtime_id: "{RUNTIME_ID}"
node_address: "unix:../{CLIENT}/internal.sock"

log:
  level: debug
  format: json
  file: ./node.log

database:
  host: "127.0.0.1"
  port: 5432
  db: "postgres"
  user: "postgres"
  password: "postgres"
  dial_timeout: 5
  read_timeout: 10
  write_timeout: 5
  max_open_conns: 0

cache:
  block_size: 10
  tx_size: 10485760
  tx_receipt_size: 10485760
  metrics: true

gateway:
  chain_id: 42261
  http:
    host: "0.0.0.0"
    port: 3000
    cors: ["*"]
  ws:
    host: "0.0.0.0"
    port: 3001
    cors: ["*"]
  monitoring:
    host: "0.0.0.0"
    port: 3002
  method_limits:
    get_logs_max_rounds: 100
```
</details>

## Nodes Deployment (deploy environment)

Copy **oasis-deploy** folder to each node with necessary sub files and folders. **Please note that for entity folder, only file entity.json need to be copied.**

After that you will have a directory structure in the server like:
```
|-- oasis-deploy/
  |-- oasis-node
  |-- oasis
  |-- genesis.json
  |-- entity-01/entity.json
  |-- seed-01/**
  |- ...
  \-- validator-02**
```

In web3 gateway node, install postgres:
```
sudo apt-get install -y postgresql
```
Set DB user and password to match the config file:
```
sudo -i -u postgres psql
postgres=# ALTER USER postgres PASSWORD 'postgres';
```

In each seed, validator, compute and client folder, run command below to start the node:
```
../oasis-node --config config.yml
```

In web3-gateway folder, run command to start the node:
```
../oasis-web3-gateway --config config.yml
```

After that the multiple validator nodes oasis network should be started.

## Check entity and validator node status (deploy environment)

### Get registered entities
In any validator node folder, run:
```
../oasis-node registry entity list -a unix:./internal.sock
```

### Check node status
In any node folder, run:
```
../oasis-node control status -a unix:./internal.sock
```

### Check entity account information
Get entity account address in entity folder:
```
ACCOUNT=`../oasis-node stake pubkey2address --public_key $(jq -r .id entity.json)`
```
Get account info under any validator, node folder:
```
../oasis-node stake account info --stake.account.address $ACCOUNT -a unix:./internal.sock 
```
