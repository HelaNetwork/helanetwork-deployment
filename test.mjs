import XMLHttpRequest from 'xhr2';
global.XMLHttpRequest = XMLHttpRequest;
import * as oasis from '@oasisprotocol/client';

//const args = require('yargs').argv;
import yargs from 'yargs/yargs';

console.log(process.argv);

const argv = yargs(process.argv.slice(2)).options({
  grpc: { type: 'string', demandOption: true },
  start: { type: 'number', default: 0 },
  dur: { type: 'number', default: 60 },
  dest: { type: 'string' },
}).parseSync();


console.info(argv)

const ENTITY_PRIVATE_KEY = argv.privKey;
const DEST_ADDR = argv.dest;
const START_TIMESTAMP = parseInt(argv.start); //epoch
const TEST_DUR = parseInt(argv.dur); //seconds
const GRPC_ENDPOINT = argv.grpc;


const nic = new oasis.client.NodeInternal(GRPC_ENDPOINT)

const stringToUint8Array = (privateKey) => {
    let buf = Buffer.from(privateKey, 'base64')
    return new Uint8Array(buf);
}

const NodeControllerReady = async() => {
    //await nic.nodeControllerWaitReady();
    //console.log('nodes', await nic.registryGetNodes(oasis.consensus.HEIGHT_LATEST));

    const chainContext = await nic.consensusGetChainContext();
    console.log('chain context from network', chainContext);

    const genesis = await nic.consensusGetGenesisDocument();

    const ourChainContext = await oasis.genesis.chainContext(genesis);
    console.log(`chain context from genesis: ${ourChainContext}`);

    if (ourChainContext !== chainContext) {
        //throw new Error('computed chain context mismatch');
        console.log('chain context mismatch!');
    }


    delete genesis.staking.ledger;
    delete genesis.staking.delegations;
    delete genesis.registry.nodes;
    delete genesis.registry.entities;
    delete genesis.extra_data;
    //console.log("genesis:", JSON.stringify(genesis, null, 4));
    //console.log("genesis:", genesis);
}

const Faucet = async(address) => {
    const chainContext = await nic.consensusGetChainContext();
    const bank = oasis.signature.NaclSigner.fromSecret(stringToUint8Array(ENTITY_PRIVATE_KEY), 'this key is not important');
    const bank_account = await nic.stakingAccount({
        height: oasis.consensus.HEIGHT_LATEST,
        owner: await oasis.staking.addressFromPublicKey(bank.public()),
    });

    const signer = new oasis.signature.BlindContextSigner(bank);

    let i;
    let success = 0;
    let errors = 0;
    let last_error = 0;
    let last_error_msg = "";
    let bank_nonce;
    let invalid_nonce = true;

    console.log(`          now: ${Date.now()/1000}`);
    console.log(`waiting until: ${START_TIMESTAMP}`);

    while (Date.now() < START_TIMESTAMP*1000) {
        await new Promise(r => setTimeout(r, 1000));
    }

    const testStart = Date.now();
    console.log(`start @${testStart/1000}`);

    for (i=1;; i++) {
        try {
            if(invalid_nonce) {
                bank_nonce = await nic.consensusGetSignerNonce({
                    account_address: await oasis.staking.addressFromPublicKey(bank.public()),
                    height: oasis.consensus.HEIGHT_LATEST,
                });
                invalid_nonce = false;
            }

            //Sending Transaction
            const tw = oasis.staking.transferWrapper();
            //tw.setNonce(bank_account.general?.nonce ?? 0);
            tw.setNonce(bank_nonce ++);
            tw.setFeeAmount(oasis.quantity.fromBigInt(0n));
            tw.setBody({
                //to: await oasis.staking.addressFromPublicKey(dst.public()),
                to: await oasis.staking.addressFromBech32(address),
                amount: oasis.quantity.fromBigInt(100n),
            });
            const gas = await tw.estimateGas(nic, bank.public());
            tw.setFeeGas(gas);

            await tw.sign(signer, chainContext);
            await tw.submit(nic);

            success ++;
        }
        catch(err) {
            errors ++;
            last_error = i;
            last_error_msg = err.toString();

            invalid_nonce = true;
        }

        if(Date.now() - testStart >= TEST_DUR * 1000) {
            break;
        }
    }

    const testEnd = Date.now();
    console.log(`,submit tx,${i},success,${success},errors,${errors},last error happend,${last_error},last error msg,${last_error_msg.replaceAll(/[,\n\r]/g, "")},duration,${(testEnd - testStart)/1000},`);

    return 0
}
    
function run() {
    return NodeControllerReady().then((x) => {
        //return Faucet(DEST_ADDR);
        return nic.consensusGetTransactionsWithResults(32092);
        //return nic.consensusGetBlock(32092);
    }).then(x => {
        //console.log(JSON.stringify(x, null, 2));
        console.log(x);
    }).catch((err) => {
        console.log(err);
    });
}

let timer = setTimeout(() => {}, 0x7fffffff);
run().then((x) => {
    timer.unref();
});
