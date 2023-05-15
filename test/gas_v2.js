var contracts = {}
const contracts_to_deploy = ['sBNB', 'sTSLA', 'Swap']
for (name of contracts_to_deploy) {
    contracts[name] = artifacts.require(name)
}

contract("Gas Estimation of Swap v2", async accounts => {
    
    it("Test 1: Gas Utilization of init", async () => {
        var instances = {};
        for (name of contracts_to_deploy) {
            instances[name] = await contracts[name].deployed();
        }

        const amount = 500000 * 10 ** 8;
        await instances['sBNB'].approve(instances['Swap'].address, amount);
        await instances['sTSLA'].approve(instances['Swap'].address, amount);
        
        // Gas Estimation of init
        const gasCost = await instances['Swap'].init.estimateGas(amount, amount);
        console.log(`Gas Cost of init: ${gasCost}`);

        await instances['Swap'].init(amount, amount);
    });

    it("Test 2: Gas Utilization of addLiquidity", async () => {
        var instances = {}
        for (name of contracts_to_deploy) {
            instances[name] = await contracts[name].deployed()
        }
        const amount = 500000 * 10 ** 8;
        await instances['sBNB'].approve(instances['Swap'].address, amount);
        await instances['sTSLA'].approve(instances['Swap'].address, amount);

        // Gas Estimation of addLiquidity
        const gasCost = await instances['Swap'].addLiquidity.estimateGas(amount);
        console.log(`Gas Cost of AddLiquidity: ${gasCost}`);        
    });

    it("Test 3: Gas Utilization of token0To1", async () => {
        var instances = {}
        for (name of contracts_to_deploy) {
            instances[name] = await contracts[name].deployed()
        }

        const tokenSent = 1000 * 10 ** 8;
        await instances['sBNB'].transfer(accounts[1], tokenSent);
        await instances['sBNB'].approve(instances['Swap'].address, tokenSent, { from: accounts[1] });

        // Gas Estimation of token0To1
        const gasCost = await instances['Swap'].token0To1.estimateGas(tokenSent, { from: accounts[1] });
        console.log(`Gas Cost of token0To1: ${gasCost}`);
    });

    it("Test 4: Gas Utilization of token1To0", async () => {
        var instances = {}
        for (name of contracts_to_deploy) {
            instances[name] = await contracts[name].deployed()
        }

        const reserves_before = await instances['Swap'].getReserves.call();

        const tokenSent = 1000 * 10 ** 8;
        await instances['sTSLA'].transfer(accounts[2], tokenSent);
        await instances['sTSLA'].approve(instances['Swap'].address, tokenSent, { from: accounts[2] });

        // Gas Estimation of token1To0
        const gasCost = await instances['Swap'].token1To0.estimateGas(tokenSent, { from: accounts[2] });
        console.log(`Gas Cost of token1To0: ${gasCost}`);        
    });

    it("Test 5: Gas Utilization of removeLiquidity", async () => {
        var instances = {}
        for (name of contracts_to_deploy) {
            instances[name] = await contracts[name].deployed()
        }

        const shares = await instances['Swap'].getShares.call(accounts[0]);

        // Gas Estimation of removeLiquidity
        const gasCost = await instances['Swap'].removeLiquidity.estimateGas(shares);
        console.log(`Gas Cost of removeLiquidity: ${gasCost}`);        
    });
});