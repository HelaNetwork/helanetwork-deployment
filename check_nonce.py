import sys
import json
import time
import signal
import functools
from threading import Thread
from multiprocessing import Process, Queue

from web3 import Web3, HTTPProvider
from web3.middleware import geth_poa_middleware


with open('tps.json') as f:
    config = json.load(f)

client_w3s = [ Web3(HTTPProvider(config["backends"][i])) for i in range(config["backend_num"])]
compute_w3 = Web3(HTTPProvider(config["compute-rpc"])) if "compute-rpc" in config else Web3(HTTPProvider(config["_compute-rpc"]))

num = config["threads_num"] * config["accounts_per_thread"]

print(f"{time.time()}: check {num} nonces ...")

diffs = 0
nonce_dist = {}

for i in range(num):
  try:
    src_addr = config["src_accounts"][i]['address']

    compute_nonce = compute_w3.eth.get_transaction_count(src_addr)

    if compute_nonce not in nonce_dist:
        nonce_dist[compute_nonce] = 0
    nonce_dist[compute_nonce] += 1

    diff_clients = []

    for c in range(len(client_w3s)):
        client_nonce = client_w3s[c].eth.get_transaction_count(src_addr)
        if client_nonce != compute_nonce:
            diffs += 1
            diff_clients.append(c)

    if len(diff_clients) > 0:
        print(f"address {src_addr} different nonce in {diff_clients}")

  except Exception as e:
    print(f"Exception: {str(e)}")

print(f"done, total {diffs} different, nonce distribution {nonce_dist}")
