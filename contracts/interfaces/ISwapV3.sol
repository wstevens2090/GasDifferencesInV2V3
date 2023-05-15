// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

interface ISwapV3 {
    function init(int24 lowerTick, int24 upperTick, uint token0Amount, uint token1Amount) external;

    function setPosition(int24 lowerTick, int24 upperTick, int128 liquidityDelta) external;

    function token0To1(uint token0Amount) external;

    function token1To0(uint token1Amount) external;
}