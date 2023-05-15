//var HDWalletProvider = require("@truffle/hdwallet-provider");
//const MNEMONIC = 'practice dawn lamp foot pumpkin blame imitate atom robot culture ride toss';
//const MNEMONIC = 'reunion want impose fat program burden soap picnic fringe wood enter myself';
module.exports = {
  networks: {
    development: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "*", 
      loggingEnabled: true,
    }
  },

  compilers: {
    solc: {
      version: '0.8.7',
      settings: {
        optimizer: {
          enabled: true,
          runs: 200
        },
      }
    }
  }
};
