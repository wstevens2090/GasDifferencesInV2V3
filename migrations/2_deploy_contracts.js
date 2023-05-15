var sBNB = artifacts.require("./sBNB.sol");
var sTSLA = artifacts.require("./sTSLA.sol");
var Swap = artifacts.require("./Swap.sol");
var SwapV3 = artifacts.require("./SwapV3.sol");

module.exports = async function(deployer, network, accounts) {
    await deployer.deploy(sBNB, 2000000);
    await deployer.deploy(sTSLA, 2000000);
    await deployer.deploy(Swap, sBNB.address, sTSLA.address);
    await deployer.deploy(SwapV3, sBNB.address, sTSLA.address, 10000, 1);
};

