import sys
import json
import time
import signal
import functools
import binascii
import argparse
from threading import Thread
from multiprocessing import Process, Queue

from web3 import Web3, HTTPProvider
from web3.middleware import geth_poa_middleware


with open('tps.json') as f:
    config = json.load(f)

parser = argparse.ArgumentParser()
parser.add_argument('--chain-id', type = int, default = 0, help = 'runtime chain id')
parser.add_argument('--network', type = str, default = "", help = 'network name')
parser.add_argument('--backend-offset', type = int, default = config["backend_offset"], help = 'offset of backend RPC')
parser.add_argument('--accounts-offset', type = int, default = config["accounts_offset"], help = 'offset of accounts')
parser.add_argument('--num-txs', type = int, default = 1, help = 'num of txs to send')
opt = parser.parse_args()

if opt.chain_id == 0:
    opt.chain_id= config["chain_id"]

def create_web3(idx):
    #{{{
    if config["use_lb"]:
        w3 = Web3(HTTPProvider(config["lb_url"]
        ))
        '''
            , request_kwargs={
                "headers": {
                    "Content-Type": "application/json",
                    "X-Backend-Select": str(i)
                }
            }
        '''
        rpc = config["lb_url"]
    else:
        i = (idx + opt.backend_offset) % config["backend_num"]
        print("creating web3 by url:", backends[i])
        w3 = Web3(HTTPProvider(backends[i]))
        rpc = backends[i]

    #w3.middleware_onion.inject(geth_poa_middleware, layer=0)
    return w3,rpc
    #}}}

if opt.network == "":
    opt.network = subprocess.getoutput('./builder exec -s -- current_network')

if opt.network not in config["backends"]:
    backends = subprocess.getoutput('./builder exec -s -- get_all_w3_urls').split('\n')
else:
    backends = config["backends"][opt.network]

if config["backend_num"] == 0:
    config["backend_num"] = len(backends)

w3s = [ create_web3(i) for i in range(config["backend_num"])]
tx_sent = []
busy = 0

print(f"{time.time()}: sending {opt.num_txs} txs from {opt.accounts_offset}...")

for i in range(opt.num_txs):
  try:
    w3 = w3s[i % config["backend_num"]][0]
    rpc = w3s[i % config["backend_num"]][1]

    src_addr = config["src_accounts"][opt.accounts_offset+i]['address']
    dst_addr = config["dst_accounts"][opt.accounts_offset+i]["address"]

    print(f"{time.time()}: using rpc {rpc}")
    print(f"{time.time()}: getting nonce/balance for {src_addr}...")
    nonce = w3.eth.get_transaction_count(src_addr)
    balance = w3.from_wei(w3.eth.get_balance(src_addr), "gwei")
    print(f"{time.time()}: got nonce {nonce}, balance {balance}")

    amt_drift = int(time.time() * 1000) % 1000 - 500

    tx = {
        'nonce': nonce,
        'to': dst_addr,
        'value': w3.to_wei(config["transfer_amt"]+amt_drift, 'gwei'),
        'gas': config['gas_limit'],
        'gasPrice': w3.to_wei(config['gas_price'], 'gwei'),
        'chainId': opt.chain_id
    }
    signed_tx = w3.eth.account.sign_transaction(tx, config["src_accounts"][opt.accounts_offset+i]['key'])

    #print(f"{time.time()}: {src_addr} => {dst_addr} sending {binascii.hexlify(signed_tx.rawTransaction).decode('utf-8')}...")
    print(f"{time.time()}: {src_addr} => {dst_addr} sending TX for {config['transfer_amt']+amt_drift} gwei...")
    start = time.time()
    tx_hash = w3.eth.send_raw_transaction(signed_tx.rawTransaction)
    print(f"{time.time()}: return tx_hash {tx_hash.hex()}")

    tx_sent.append({
        "status": "busy",
        "src": src_addr,
        "dst": dst_addr,
        "nonce": nonce,
        "hash": tx_hash.hex(),
        "ts": time.time(),
        "start": start,
        "errors": 0
    })
    busy += 1

  except Exception as e:
    print(f"{time.time()}: Exception: {str(e)}")

while busy > 0:
    for x in tx_sent:
        if x["status"] != "busy":
            continue
        try:
            nonce = w3.eth.get_transaction_count(x["src"])
            if nonce > x["nonce"]:

                end = time.time()
                print(f"{time.time()}: src {x['src']} nonce {nonce} > {x['nonce']}, query tx transaction and receipt...")
                transaction = w3.eth.get_transaction(x["hash"])
                receipt = w3.eth.get_transaction_receipt(x["hash"])

                x["status"] = "idle"
                busy -= 1

                print(f"{time.time()}: {x['src']} => {x['dst']} done, new nonce {nonce}, dur ${end-x['start']}")
            elif time.time() - x["ts"] > 60:
                print(f"{x['src']} => {x['dst']} timeout")
                x["status"] = "timeout"
                busy -= 1
        except Exception as e:
            print(f"Exception: {str(e)}")
            x['errors'] += 1
            if x['errors'] >= 5:
                print(f"{time.time()}: src {x['src']} 5 errors, not retry")
                x["status"] = "error"
                busy -= 1
    time.sleep(1)

