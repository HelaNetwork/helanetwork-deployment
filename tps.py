import sys
import json
import time
import math
import signal
import functools
import argparse
import os
import subprocess
from pathlib import Path
from threading import Thread
from multiprocessing import Process, Queue
from datetime import datetime
from random import randrange

from web3 import Web3, HTTPProvider
from web3.middleware import geth_poa_middleware


with open('tps.json') as f:
    config = json.load(f)

parser = argparse.ArgumentParser()
parser.add_argument('--network', type = str, default = "", help = 'network name')
parser.add_argument('--chain-id', type = int, default = 0, help = 'runtime chain id')
parser.add_argument('--accounts-offset', type = int, default = config["accounts_offset"], help = 'offset of accounts')
parser.add_argument('--backend-num', type = int, default = config["backend_num"], help = 'num of backend RPC')
parser.add_argument('--backend-offset', type = int, default = config["backend_offset"], help = 'offset of backend RPC')
parser.add_argument('--threads-num', type = int, default = config["threads_num"], help = 'num of test threads')
parser.add_argument('--start-time', type = int, default = 0, help = 'start timestamp (s)')
parser.add_argument('--check-only', dest='check_only', action='store_true', help='check only')
parser.set_defaults(check_only=False)
parser.add_argument('--no-check', dest='no_check', action='store_true', help='no check')
parser.set_defaults(no_check=False)
parser.add_argument('--read-nonce', dest='read_nonce', action='store_true', help='read nonce')
parser.set_defaults(read_nonce=False)
parser.add_argument('--rm-nonce', dest='rm_nonce', action='store_true', help='read nonce')
parser.set_defaults(rm_nonce=False)
opt = parser.parse_args()

if opt.network == "":
    opt.network = subprocess.getoutput('./builder exec -s -- current_network')

if opt.network not in config["backends"]:
    backends = subprocess.getoutput('./builder exec -s -- get_all_w3_urls').split('\n')
else:
    backends = config["backends"][opt.network]

if opt.backend_num == 0:
    opt.backend_num = len(backends)

if opt.threads_num == 0:
    opt.threads_num = opt.backend_num

if opt.chain_id == 0:
    opt.chain_id= config["chain_id"]

blk_confirm_shift = 5

def create_web3(idx):
    #{{{
    if config["use_lb"]:
        i = 0
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
    else:
        i = (idx + opt.backend_offset) % opt.backend_num
        w3 = Web3(HTTPProvider(backends[i]))

    #w3.middleware_onion.inject(geth_poa_middleware, layer=0)
    return w3, i
    #}}}

def submit_transaction(w3, src, dst, amount, last_nonce=None, wait=False):
    #{{{
    #print("  transferring {} to {}, amount {}".format(src["address"], dst["address"], amount))
    #start_time = time.time()

    nonce = w3.eth.get_transaction_count(src['address'])
    while last_nonce != None and nonce < last_nonce:
        print(f"    fix nonce {nonce} to {last_nonce} for addr {src['address']}")
        nonce = last_nonce
        break
        time.sleep(0.01)
        nonce = w3.eth.get_transaction_count(src['address'])
    #print(f"    tx_nonce {nonce} addr {src['address']}")

    tx = {
        'nonce': nonce,
        'to': dst["address"],
        'value': w3.to_wei(amount, 'gwei'),
        'gas': config['gas_limit'],
        'gasPrice': w3.to_wei(config['gas_price'], 'gwei'),
        'chainId': opt.chain_id
    }
    signed_tx = w3.eth.account.sign_transaction(tx, src['key'])
    tx_hash = w3.eth.send_raw_transaction(signed_tx.rawTransaction)
    #print(f"    tx_hash {tx_hash.hex()}")

    while wait:
        #receipt = w3.eth.wait_for_transaction_receipt(tx_hash, poll_latency=0.2)
        #print(receipt.status)
        #break
        time.sleep(0.2)
        nonce = w3.eth.get_transaction_count(src['address'])
        if nonce > tx["nonce"]:
            #print(f'    new nonce: {nonce}')
            break

    #elapsed_time = time.time() - start_time
    #print(f'    Transactions dur: {elapsed_time}s')

    return tx_hash,nonce
    #}}}

def test_thread(param):
    #{{{
    start_idx = param["acc_start"]
    w3, w3_idx = create_web3(param["index"])
    group = []
    running = True
    busy = 0
    blocks = {}
    end_ts = 0

    print(f"#{param['index']} using w3 #{w3_idx} acc start idx {start_idx} param start time @{param['start']} actual time {time.time()}")

    while True:
        cycle_start = time.time()
        sent_count = 0
        nonce_changes = 0
        receipt_confirms = 0
        read_count = 0
        read_total = 0
        finished = 0

        amt_drift = int(cycle_start * 1000) % 1000 - 500

        print(f"#{param['index']}, {cycle_start-param['start']:.6f}, {cycle_start:.6f}, cycle start...")

        for i in range(config["accounts_per_thread"]):
            if running and time.time()-param["start"] >= config["test_duration"]:
                print(f"#{param['index']} stopping test by set running = False")
                running = False

            if i >= len(group):
                group.append({
                    "status": "idle",
                    "sent": 0,
                    "errors": 0
                })

            src = config["src_accounts"][start_idx + i]
            #dst = config["dst_accounts"][start_idx + i]

            if group[i]["status"] == "idle":
                if group[i]["sent"] >= config["rounds_num"]:
                    finished += 1
                    continue

                if busy >= config["max_pending_txs"] or not running:
                    continue

                '''
                '''
                dst_idx = i
                while dst_idx == i:
                    dst_idx = randrange(int(config["accounts_per_thread"]/10))
                #dst_idx = i - i%10
                
                dst = config["src_accounts"][start_idx + dst_idx]

                try:
                    #{{{
                    if src['address'] in param['nonces']:
                        nonce = param['nonces'][src['address']]
                    else:
                        nonce = w3.eth.get_transaction_count(src['address'])
                    group[i]["last_nonce"] = nonce

                    if "nonce_shift" in group[i]:
                        nonce += group[i]["nonce_shift"]
                    tx = {
                        'nonce': nonce,
                        'to': dst["address"],
                        'value': w3.to_wei(config["transfer_amt"] + amt_drift, 'gwei'),
                        'gas': config['gas_limit'],
                        'gasPrice': w3.to_wei(config['gas_price'], 'gwei'),
                        'chainId': opt.chain_id
                    }
                    signed_tx = w3.eth.account.sign_transaction(tx, src['key'])

                    submit_start = time.time()

                    tx_hash = w3.eth.send_raw_transaction(signed_tx.rawTransaction)

                    #print(f"#{param['index']} acc #{i} {src['address']} => #{dst_idx} {dst['address']} sent, nonce {nonce} tx_hash {tx_hash.hex()}")

                    group[i]["nonce_shift"] = 0
                    group[i]["status"] = "busy"
                    group[i]["nonce"] = nonce
                    group[i]["tx_hash"] = tx_hash.hex()
                    group[i]["submitting"] = submit_start
                    group[i]["submitted"] = time.time()
                    group[i]["last_check"] = time.time()
                    group[i]["sent"] += 1
                    group[i]["errors"] = 0
                    group[i]["dst"] = dst
                    busy += 1
                    sent_count += 1
                    #}}}
                except Exception as e:
                    group[i]["nonce_shift"] = 0
                    group[i]["errors"] += 1
                    print(f"#{param['index']} acc #{i} address {src['address']} nonce {nonce} submit tx error #{group[i]['errors']}: {str(e)}")
                    if group[i]["errors"] >= 5:
                        group[i]["status"] = "error"
                        param["stopped"] += 1

            elif group[i]["status"] == "busy":
                if time.time() - group[i]["last_check"] < 0.5:  # checking interval
                    continue

                dst = group[i]["dst"]
                try:
                    #{{{
                    group[i]["last_check"] = time.time()
                    s = time.time()
                    nonce = w3.eth.get_transaction_count(src['address'])
                    read_count += 1
                    read_total += time.time() - s
                    if nonce != group[i]["last_nonce"]:
                        #print(f"#{param['index']} acc {src['address']} => {dst['address']} nonce changed {group[i]['last_nonce']} => {nonce}")
                        nonce_changes += 1
                        group[i]["last_nonce"] = nonce

                    if nonce > group[i]["nonce"]:
                        s = time.time()
                        receipt = w3.eth.get_transaction_receipt(group[i]["tx_hash"])
                        read_count += 1
                        read_total += time.time() - s

                        block_no = receipt.blockNumber
                        if block_no not in blocks:
                            s = time.time()
                            blocks[block_no] = w3.eth.get_block(block_no)
                            read_count += 1
                            read_total += time.time() - s
                        block = blocks[block_no]

                        receipt_confirms += 1
                        #print(f"#{param['index']} acc {src['address']} => {dst['address']} receipt read with nonce {nonce}")

                        if receipt.status == 0:
                            param["failed"] += 1
                        else:
                            param["success"] += 1
                        param['nonces'][src['address']] = nonce

                        timestamp = time.time()
                        block_ts = block.timestamp
                        param['txs'].append({
                            "submitting": group[i]["submitting"] - param["start"],
                            "submitted" : group[i]["submitted"]  - param["start"],
                            "confirmed" : timestamp              - param["start"],
                            "submitting_ts": int(group[i]["submitting"] - param["start"]),
                            "submitted_ts" : int(group[i]["submitted"]  - param["start"]),
                            "confirmed_ts" : int(block_ts               - param["start"] + blk_confirm_shift) - blk_confirm_shift,
                            "submit_latency": group[i]["submitted"] - group[i]["submitting"],
                            "latency": timestamp - group[i]["submitted"],
                            "tx_hash": group[i]["tx_hash"],
                            "blk_number": block_no
                        })

                        group[i]["status"] = "idle"
                        group[i]["nonce"] = nonce
                        group[i]["errors"] = 0
                        busy -= 1
                        if timestamp > end_ts:
                            end_ts = timestamp
                    elif time.time() - group[i]["submitted"] > config["tx_timeout"]:
                        print(f"#{param['index']} acc #{i} {src['address']} => {dst['address']} nonce {nonce} tx_hash {group[i]['tx_hash']} confirm tx timeout")
                        group[i]["status"] = "timeout"
                        param["stopped"] += 1
                        param["unsent"] += config["rounds_num"]-group[i]["sent"]
                        busy -= 1
                    #}}}
                except Exception as e:
                    group[i]["errors"] += 1
                    if group[i]["errors"] >= 5:
                        print(f"#{param['index']} acc #{i} {src['address']} => {dst['address']} nonce {nonce} tx_hash {group[i]['tx_hash']} confirm tx error #{group[i]['errors']}: {str(e)}")
                        group[i]["status"] = "error"
                        param["stopped"] += 1
                        param["unsent"] += config["rounds_num"]-group[i]["sent"]
                        busy -= 1

            if group[i]["status"] == "timeout" or group[i]["status"] == "error":
                finished += 1

        # end of for accounts_per_thread

        cycle_end = time.time()
        print(f"#{param['index']}, {cycle_end-param['start']:.6f}, {cycle_end:.6f}, cycle end, {i+1}/{config['accounts_per_thread']}, reads, {read_count}/{read_total:.6f}s, sents, {sent_count}, nonce changed, {nonce_changes}, receipt confirms, {receipt_confirms}, pending, {busy}")

        if finished == config["accounts_per_thread"]:
            print(f"#{param['index']} stop testing due to all finished {finished}")
            break

        if busy == 0 and not running:
            print(f"#{param['index']} stop testing due to 0 busy")
            break

        if read_count + sent_count == 0:
            time.sleep(0.5)
        else:
            time.sleep(0.1)
    # end of while

    for b in blocks:
        param['blks'].append(int(blocks[b].timestamp - param["start"] + blk_confirm_shift) - blk_confirm_shift)

    param['duration'] = end_ts - param["start"]
    print(f"#{param['index']} finished with success {param['success']} failed {param['failed']} duration {param['duration']} last submit {submit_start}")
    #}}}

def test_proc(q):
    #{{{
    x = q.get()
    with open(x["fn"]) as f:
        param = json.load(f)

    test_thread(param)

    with open(x["fn"], 'w') as f:
        json.dump(param, f, indent=2)
    q.put(x)
    #}}}

def calc_offers(a):
    #{{{
    gas_fee = config["gas_limit"] * config["gas_price"]
    o = 1
    while int((a - gas_fee) / 2) >= config["account_threshold"] * 2:
        o *= 2
        a = int((a - gas_fee) / 2)
    return o - 1
    #}}}

def calc_inject(o):
    #{{{
    gas_fee = config["gas_limit"] * config["gas_price"]
    amt = config["account_threshold"] * 2
    offers = 1
    while offers < o:
        amt = amt * 2 + gas_fee
        offers *= 2
    return amt
    #}}}

# gwei
def get_balance(w3, addr):
    return w3.from_wei(w3.eth.get_balance(addr), "gwei")

def check_proc(acc_offset):
    #{{{
    w3,_ = create_web3(0)

    added = False
    for i in range(config["accounts_num"]):
        #{{{
        if i >= len(config["src_accounts"]):
            acc = w3.eth.account.create()
            config["src_accounts"].append({
                "address": acc.address,
                "key": acc.key.hex()
            })
            print("added src acc:", config["src_accounts"][i])
            added = True

        if i >= len(config["dst_accounts"]):
            acc = w3.eth.account.create()
            config["dst_accounts"].append({
                "address": acc.address,
                "key": acc.key.hex()
            })
            print("added dst acc:", config["dst_accounts"][i])
            added = True
        #}}}

    if added:
        with open('tps.json', 'w') as f:
            json.dump(config, f, indent=2)

    gas_fee = config["gas_limit"] * config["gas_price"]
    threshold = config["account_threshold"]
    supply_acc = []
    demand_acc = []
    total_offers = 0

    supply_acc.append({
        "acc": config["token_cache"],
        "balance": get_balance(w3, config["token_cache"]["address"]),
        "offers": 0,
        "status": "idle",
        "index": -1
    })

    for i in range(opt.threads_num * config["accounts_per_thread"]):
        #{{{
        src_acc = config["src_accounts"][acc_offset + i]
        balance = get_balance(w3, src_acc["address"])

        if balance < threshold:
            demand_acc.append({
                "acc": src_acc,
                "balance": balance,
                "status": "idle",
                "index": i
            })
            continue

        offers = calc_offers(balance)
        if offers > 0:
            supply_acc.append({
                "acc": src_acc,
                "balance": balance,
                "offers": offers,
                "status": "idle",
                "index": i
            })
            total_offers += offers
            #print(f"src #{i} {src_acc['address']} balance {balance} offers {offers}")
        #}}}

    print(f"total_offers {total_offers}, supply {len(supply_acc)}, demand {len(demand_acc)}")

    busy = 0
    while busy > 0 or len(demand_acc) > 0:
        #print(f".busy {busy}, len of demand_acc {len(demand_acc)}")

        next_supply_idx = 1
        for i in range(len(demand_acc)-1,-1,-1):
            #{{{
            supply_idx = None

            if total_offers < len(demand_acc) and supply_acc[0]["status"] == "idle":
                amt = calc_inject(len(demand_acc) - total_offers)
                if supply_acc[0]["balance"] >= amt:
                    print(f"injecting {amt} token from cache with offers {calc_offers(amt)} and balance {supply_acc[0]['balance']}")
                    supply_idx = 0
                else:
                    print("cache acc balance not enough!", supply_acc[0]["balance"], amt)
                    supply_acc[0]["status"] = "low-supply"

            if supply_idx == None:
                supply_idx = next((x for x in range(next_supply_idx, len(supply_acc)) if supply_acc[x]["status"] == "idle"), None)
                if supply_idx == None:
                    break
                next_supply_idx = supply_idx + 1
                amt =int((supply_acc[supply_idx]["balance"] - gas_fee) / 2)

            tx_hash,nonce = submit_transaction(
                w3,
                supply_acc[supply_idx]["acc"],
                demand_acc[i]["acc"],
                amt
            )
            print("acc #{} balance {} too low, transfer {} from #{}, tx_hash {}".format(
                demand_acc[i]["index"] + acc_offset,
                demand_acc[i]["balance"],
                amt,
                supply_acc[supply_idx]["index"],
                tx_hash.hex()
            ))

            supply_acc[supply_idx]["status"] = "busy"
            supply_acc[supply_idx]["hash"] = tx_hash.hex()
            supply_acc[supply_idx]["nonce"] = nonce
            supply_acc[supply_idx]["dest"] = demand_acc[i]
            supply_acc[supply_idx]["start"] = time.time()
            demand_acc.pop(i)
            busy += 1
            if busy >= 200:
                break
            #}}}

        if busy == 0:
            print("no enough offers!! left demands:", len(demand_acc))
            break

        for i in range(len(supply_acc)):
            if supply_acc[i]["status"] == "busy":
                # {{{
                nonce = w3.eth.get_transaction_count(supply_acc[i]["acc"]['address'])
                if nonce <= supply_acc[i]["nonce"]:
                    if time.time() - supply_acc[i]["start"] > config["tx_timeout"]:
                        print("{} => {} timeout on {} once {} tx_hash {}".format(
                            supply_acc[i]["acc"]['address'],
                            supply_acc[i]["dest"]["acc"]['address'],
                            time.time(),
                            nonce,
                            supply_acc[i]["hash"]
                        ))

                        dest = supply_acc[i]["dest"]
                        balance = get_balance(w3, dest["acc"]['address'])

                        if balance < threshold:
                            print(f"dest ${dest['index']} {dest['acc']['address']} has no enough balance")
                            #demand_acc.append(supply_acc[i]["dest"])
                        else:
                            print(f"dest ${dest['index']} {dest['acc']['address']} has enough balance {balance}")

                        del(supply_acc[i]["dest"])

                        supply_acc[i]["status"] = "timeout"
                        busy -= 1
                    continue
                busy -= 1

                supply_acc[i]["balance"] = get_balance(w3, supply_acc[i]["acc"]["address"])
                if i == 0:
                    supply_acc[i]["status"] = "idle"
                else:
                    total_offers -= supply_acc[i]["offers"]
                    supply_acc[i]["offers"] = calc_offers(supply_acc[i]["balance"])
                    supply_acc[i]["status"] = "idle" if supply_acc[i]["offers"] > 0 else "no-offer"
                    total_offers += supply_acc[i]["offers"]

                dest = supply_acc[i]["dest"]
                del(supply_acc[i]["dest"])

                dest["balance"] = get_balance(w3, dest["acc"]["address"])
                if dest["balance"] < threshold:
                    print(f"demand acc #${dest['index']} {dest['acc']['address']} has no enough balance, retrying")
                    demand_acc.append(dest)
                else:
                    dest["offers"] = calc_offers(dest["balance"])
                    if dest["offers"] > 0:
                        dest["status"] = "idle"
                        total_offers += dest["offers"]
                        supply_acc.append(dest)

                #print(f"total_offers {total_offers}")
                #}}}

        time.sleep(1)
    #}}}

def nonce_proc(acc_offset):
    #{{{
    w3,_ = create_web3(0)
    nonces = {}
    total = 0
    fn = f'.src_nonce.json'

    if os.path.exists(fn):
        os.remove(fn)

    for i in range(config["accounts_per_thread"] * opt.threads_num):
        src = config["src_accounts"][acc_offset + i]
        try:
            nonce = w3.eth.get_transaction_count(src['address'])
            nonces[src['address']] = nonce
            total += 1
        except Exception as e:
            print(f"acc #{i} {src['address']} read nonce error: {str(e)}")

    with open(fn, 'w') as f:
        json.dump(nonces, f, indent=2)

    print(f"read nonce done @ {time.time()}, total read: {total}")
    #json.dump(nonces, sys.stdout, indent=2)
    #}}}

def main():
    #{{{
    signal.signal(signal.SIGINT, lambda s,f: sys.exit(1))

    acc_offset = opt.accounts_offset
    
    if opt.threads_num * config["accounts_per_thread"] + acc_offset > config["accounts_num"]:
        print("accounts num not enough")
        sys.exit(1)

    if opt.read_nonce:
        print(f"read nonce @ {time.time()}")

        p = Process(target=nonce_proc, args=(acc_offset,))
        p.start()
        p.join()
        return 0

    if opt.rm_nonce:
        fn = f'.src_nonce.json'
        if os.path.exists(fn):
            os.remove(fn)
        return 0

    if not opt.no_check:
        p = Process(target=check_proc, args=(acc_offset,))
        p.start()
        p.join()

    if opt.check_only:
        return 0


    print(f"testing with threads {opt.threads_num} accounts/thread {config['accounts_per_thread']} duration {config['test_duration']} acc offset {acc_offset}")

    '''
    sys.stdout.write('Press Enter when ready... ')
    sys.stdout.flush()
    sys.stdin.read(1)
    '''

    # testing
    real_start = time.time()
    start_time = opt.start_time if opt.start_time != 0 else real_start
    while real_start < start_time:
        time.sleep(0.01)
        real_start = time.time()

    threads = []
    params = []
    queues = []
    nonces = {}

    fn = f'.src_nonce.json'
    if os.path.exists(fn):
        with open(fn) as f:
            nonces = json.load(f)

    print(f"testing starting @ {time.time()}")

    for i in range(opt.threads_num):
        acc_start = acc_offset + i * config["accounts_per_thread"]
        param = {
            "index": i,
            "acc_start": acc_start,
            "start": start_time,
            "success": 0,
            "failed": 0,
            "stopped": 0,
            "unsent": 0,
            "txs": [],
            "blks": [],
            "duration": 0,
            "nonces": nonces
        }

        if config["use_process"]:
            fn = f'.tps_param_{i}.json'
            with open(fn, 'w') as f:
                json.dump(param, f, indent=2)
            q = Queue()
            q.put({"fn": fn})
            t = Process(target=test_proc, args=(q,))
            queues.append(q)
        else:
            t = Thread(target=test_thread, kwargs={ "param": param })
            params.append(param)

        t.start()
        threads.append(t)

    for t in threads:
        t.join()

    print(f"testing end @ {time.time()}")

    if config["use_process"]:
        for q in queues:
            x = q.get()
            with open(x["fn"]) as f:
                param = json.load(f)
            Path.unlink(Path(x["fn"]))
            params.append(param)

    all_txs = functools.reduce(lambda x,y: x+y["txs"], params, [])
    all_blks = functools.reduce(lambda x,y: x+y["blks"], params, [])

    with open('txs.json', 'w') as f:
        json.dump(all_txs, f, indent=2)

    max_dur = max(x["duration"] for x in params)

    print("all done with start time {} real {} success {} failed {} stopped {} unsent {} duration {} tps {}".format(
        start_time,
        real_start,
        sum(p['success'] for p in params),
        sum(p['failed'] for p in params),
        sum(p['stopped'] for p in params),
        sum(p['unsent'] for p in params),
        max_dur,
        sum(p['success'] for p in params)/max_dur
    ))

    print("  submit latency max {} min {} avg {}".format(
        max(t['submit_latency'] for t in all_txs),
        min(t['submit_latency'] for t in all_txs),
        sum(t['submit_latency'] for t in all_txs)/len(all_txs)
    ))
    print("  latency max {} min {} avg {}".format(
        max(t['latency'] for t in all_txs),
        min(t['latency'] for t in all_txs),
        sum(t['latency'] for t in all_txs)/len(all_txs)
    ))

    max_ts = max(x["confirmed"] for x in all_txs)
    max_ts = math.ceil(max_ts)

    submitting_per_s = [sum(1 for x in all_txs if x["submitting_ts"] == t) for t in range(-blk_confirm_shift, max_ts)]
    print("  submittings/s max {} avg {}".format(
        max(submitting_per_s),
        sum(submitting_per_s)/len(submitting_per_s)
    ))

    submitted_per_s = [sum(1 for x in all_txs if x["submitted_ts"] == t) for t in range(-blk_confirm_shift, max_ts)]
    print("  submitteds/s max {} avg {}".format(
        max(submitted_per_s),
        sum(submitted_per_s)/len(submitted_per_s)
    ))

    confirmed_per_s = [sum(1 for x in all_txs if x["confirmed_ts"] == t) for t in range(-blk_confirm_shift, max_ts)]
    print("  confirms/s max {} avg {}".format(
        max(confirmed_per_s),
        sum(confirmed_per_s)/len(confirmed_per_s)
    ))

    print("timestamp,submitting,submitted,confirmed,block confirm")
    for t in range(max_ts + blk_confirm_shift):
        if submitting_per_s[t] > 0 or submitted_per_s[t] > 0 or confirmed_per_s[t] > 0 or (t-blk_confirm_shift) in all_blks:
            print(f"{t-blk_confirm_shift},{submitting_per_s[t]},{submitted_per_s[t]},{confirmed_per_s[t]},{1 if (t-blk_confirm_shift) in all_blks else 0}")
    #}}}

exit(main())
