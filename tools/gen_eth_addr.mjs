import Wallet from 'ethereumjs-wallet'

const EthWallet = Wallet.default.generate();
console.log("address: " + EthWallet.getAddressString());
console.log("privateKey: " + EthWallet.getPrivateKeyString());
