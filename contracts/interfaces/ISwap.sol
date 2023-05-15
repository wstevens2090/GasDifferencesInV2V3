// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

interface ISwap {
    function init(uint256 token0Amount, uint256 token1Amount) external;

    function addLiquidity(uint256 token0Amount) external;

    function removeLiquidity(uint256 withdrawShares) external;

    function token0To1(uint256 token0Amount) external;

    function token1To0(uint256 token1Amount) external;
}
