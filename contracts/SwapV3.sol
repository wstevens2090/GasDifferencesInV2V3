// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ISwapV3.sol";
import "./sAsset.sol";
// import "https://github.com/abdk-consulting/abdk-libraries-solidity/blob/master/ABDKMathQuad.sol";
// import "https://github.com/abdk-consulting/abdk-libraries-solidity/blob/master/ABDKMath64x64.sol";
import "abdk-libraries-solidity/ABDKMathQuad.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import "truffle/Console.sol";


contract SwapV3 is Ownable, ISwapV3 {

    event LogMessage(string message);
    event LogMessage(uint num);	
// structs for tick and position type
    struct Tick {
        int128 liquidityNet;
        uint128 liquidityGross;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    struct Position {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    // global pool state
    uint256 _totalLiquidity;    // total liquidity reserves in the pool
    uint128 _liquidity;         // current activated liquidity   
    uint160 _sqrtPriceX96;      // root of the current price
    int24 _currentTick;         // currentTick the pool is at
    uint256 _feeGrowthGlobal0X128;  // fees per unit of liquidity earned in token0
    uint256 _feeGrowthGlobal1X128;  // fees per unit of liquidity earned in token1

    // global mappings
    mapping (bytes32 => Position) positions;    // msg.sender, leftTick, rightTick => Position
    mapping (int24 => Tick) ticks;              // tick index to actual tick
    // keeping track of initialized ticks implicitly using the gross liquidity at a tick

    // other contract state
    address token0;
    address token1;

    // ticks from -100,000 to 100,000 should give us a price range large enough
    int24 _maxTick;
    int24 _minTick;
    uint24 _tickSpacing;

    constructor(address addr0, address addr1, uint24 maxUpperTick, uint24 ts) {
        token0 = addr0;
        token1 = addr1;

        // enforce some bounds for tick range supported by contract
        require(maxUpperTick >= 0, "max upper tick should be positive");
        require(maxUpperTick <= 1000000, "unnecessarily large price range");
        require(maxUpperTick * 2 / ts <= 100000, "too many ticks with these parameters");

        // spacing and ranges of ticks
        _maxTick = int24(maxUpperTick);
        _minTick = -_maxTick;
        _tickSpacing = ts;
    }

    // get the value of the reserves currently activated in the contract
    // using current activated liquidity and the current root price
    function getReserves() external view returns (uint, uint) {
        return (_liquidity/_sqrtPriceX96, _liquidity * _sqrtPriceX96);
    }

    // called only when there is no position registered in the pool (no liquidity)
    // initial liquidity and price determined by the amounts of token0 and token1
    function init(int24 lowerTick, int24 upperTick, uint token0Amount, uint token1Amount) external override onlyOwner{
        
        // check there is no liquidity
        require(_totalLiquidity == 0, "init - already has liquidity");
        require(token0Amount > 0 && token1Amount > 0, "init - both tokens are needed");

        // check that ticks create a range and spacing is right
        require(lowerTick >= _minTick && lowerTick < _maxTick, "lower tick should be within range");
        require(upperTick > _minTick && upperTick <= _maxTick, "upper tick should be within range");
        require(lowerTick < upperTick, "lower tick should be lower than upper tick");
        require(uint24(lowerTick) % _tickSpacing == 0, "lower tick does not adhere to spacing");
        require(uint24(upperTick) % _tickSpacing == 0, "upper tick does not adhere to spacing");

        // transfer the funds
        require(sAsset(token0).transferFrom(msg.sender, address(this), token0Amount), "failed to transfer token0");
        require(sAsset(token1).transferFrom(msg.sender, address(this), token1Amount), "failed to transfer token1");
        /* 
        INIT GLOBAL STATE
        set initial liquidity to be the geometric mean of the reserves
        price is in terms of token0 (how much token1 traders pay for a unit of token0) 
        current tick should be at the lowerTick (that's where we have activated liquidity)
        set global fees in terms of both tokens to 0
        */
        _liquidity = uint128(sqrt(token0Amount * token1Amount));
        _totalLiquidity = _liquidity;
        _sqrtPriceX96 = uint160(sqrt(token1Amount / token0Amount));
        _currentTick = lowerTick;
        _feeGrowthGlobal0X128 = 0;
        _feeGrowthGlobal1X128 = 0;

        /*
        INIT TICKS AND POOL-OPENING POSITION
        */
        ticks[lowerTick] = Tick((int128(_liquidity)), _liquidity, 0, 0);
        ticks[upperTick] = Tick(-(int128(_liquidity)), _liquidity, 0, 0);
        positions[keccak256(abi.encodePacked(msg.sender, lowerTick, upperTick))] = Position(_liquidity, 0, 0);
    }

    // set position is used to update a position and claim uncollected fees for a liquidity provider.
    function setPosition(int24 lowerTick, int24 upperTick, int128 liquidityDelta) external override {

        // check that ticks create a range and that the spacing is right
        require(lowerTick >= _minTick && lowerTick < _maxTick, "lower tick should be within range");
        require(upperTick > _minTick && upperTick <= _maxTick, "upper tick should be within range");
        require(lowerTick < upperTick, "lower tick should be lower than upper tick");
        require(uint24(lowerTick) % _tickSpacing == 0, "lower tick does not adhere to spacing");
        require(uint24(upperTick) % _tickSpacing == 0, "upper tick does not adhere to spacing");

        // calculate the uncollected fees at this position since it was last touched
        (uint256 fu0, uint256 fu1) = getUncollectedFees(msg.sender, lowerTick, upperTick);

        // call helpers depending on whether we are adding liquidity or removing liquidity from position
        if (liquidityDelta >= 0) {
            addLiquidity(msg.sender, lowerTick, upperTick, uint128(liquidityDelta));
        }
        else {
            removeLiquidity(msg.sender, lowerTick, upperTick, uint128(-liquidityDelta));
        }

        // send the fees to the position owner
        require(sAsset(token0).transfer(msg.sender, fu0), "failed to transfer token0 fees");
        require(sAsset(token1).transfer(msg.sender, fu1), "failed to transfer token1 fees");
    }

    // swap token0 for token1
    function token0To1(uint token0Amount) external override {

        // charge fees and find residual token0 amount to trade
    	uint256 delta_fg0 = token0Amount * 3 / 1000;
        uint256 token0Amount_in = token0Amount - delta_fg0;
	
        // update global fees per liquidity unit for the contract for token0
        _feeGrowthGlobal0X128 = ((_feeGrowthGlobal0X128 * _totalLiquidity) + delta_fg0) / _totalLiquidity;
        // calculate amount of token1 to be sent out using token0Amount_in
        (uint r_0, uint r_1) = this.getReserves();
        uint token1End = (r_0 * r_1) / (r_0 + token0Amount_in);
        uint token1Amount = r_1 - token1End;
	
        /* IMPORTANT: starting price in our current tick (which will be updated as swaps happen across multiple ticks) */
        uint160 sqrtPrice_mvt = _sqrtPriceX96;

        // update the new sqrt price (subtract delta sqrt price)
        // no need to update the amount of reserves because getReserves() tells us that using L and root(P)
        uint160 delta_sqrtPrice = uint160(token1Amount / _liquidity);
        _sqrtPriceX96 -= delta_sqrtPrice;

        // now execute the trade over multiple ticks going towards the left pricerange endpoint
        uint token1Transferred = 0;
        int24 tick_counter = _currentTick;

        // transfer token0 into this contract
        require(sAsset(token0).transferFrom(msg.sender, address(this), token0Amount), "failed to transfer token0");

        while (tick_counter >= _minTick) {

            // 1. find the next initialized tick
            int24 t_s = tick_counter - int24(_tickSpacing);
            while (t_s >= _minTick) {
                if (ticks[t_s].liquidityGross > 0) break;
                t_s -= int24(_tickSpacing);
            }

            // 2. find root(P) at this next initialized tick
            bytes16 rootPrice_t_s_bytes = ABDKMathQuad.sqrt(exp_10001(t_s));
            uint160 rootPrice_t_s = uint160(ABDKMathQuad.toUInt(rootPrice_t_s_bytes));

            // 3. if delta_sqrtPrice causes global root price (the new _sqrtPriceX96) to move past this next initialized tick
            // price, then execute the trade only up to this boundary
            if (_sqrtPriceX96 < rootPrice_t_s && ticks[t_s].liquidityGross > 0) {
                // only execute part of the swap (from sqrtPrice_mvt to rootPrice_t_s)
                uint token1toSend = (sqrtPrice_mvt - rootPrice_t_s) * _liquidity;
                require(sAsset(token1).transfer(msg.sender, token1toSend), "failed to send chunk of token1 in transfer");
                token1Transferred += token1toSend;
		
                // update sqrtPrice_mvt to the price at this next initialized tick boundary
                sqrtPrice_mvt = rootPrice_t_s;

                // cross tick to the next initialized tick and continue to execute remainder of the swap
                ticks[tick_counter].feeGrowthOutside0X128 = _feeGrowthGlobal0X128 - ticks[tick_counter].feeGrowthOutside0X128;
                int128 tick_nl = ticks[t_s].liquidityNet;
                if (tick_nl > 0) {
                    _liquidity += uint128(tick_nl);
                } else {
                    _liquidity -= uint128(-tick_nl);
                }

                // move tick counter to the next initialized tick
                tick_counter = t_s;
            } else {
                // execute the whole outstanding amount within this tick and break
                require(sAsset(token1).transfer(msg.sender, token1Amount - token1Transferred), "failed to send last chunk of token1 in transfer");
                token1Transferred += token1Amount - token1Transferred;
		        tick_counter = t_s;
		        break;
            }
        }

        // set the current tick to be the final value of tick_counter
        _currentTick = tick_counter;
        require(token1Transferred == token1Amount, "failed to complete transfer correctly in amount");
    }
    
    // swap token1 for token0
    function token1To0(uint token1Amount) external override {
        
        require(token1Amount > 0, "token1Amount must be greater than 0");

        // charge fees and find residual token1 amount to trade
        uint256 delta_fg1 = token1Amount * 3 / 1000;
        uint256 token1Amount_in = token1Amount - delta_fg1;

        // update global fees per liquidty unit for the contract for token0
        _feeGrowthGlobal1X128 = ((_feeGrowthGlobal1X128 * _totalLiquidity) + delta_fg1) / _totalLiquidity;

        // calculate amount of token0 to be sent out using token1Amount_in
        (uint r_0, uint r_1) = this.getReserves();
        uint token0End = (r_0 * r_1) / (r_1 + token1Amount_in);
        uint token0Amount = r_0 - token0End;

        /* IMPORTANT: starting price in our current tick (which will be updated as swaps happen across
        multiple ticks */
        uint160 sqrtPrice_mvt = _sqrtPriceX96;

        // update the new sqrt price (to the price that this trade will move root(P) to) 6.15
        uint160 delta_sqrtPrice = uint160(_liquidity / token0Amount);
        _sqrtPriceX96 += delta_sqrtPrice;            

        // now execute the trade over multiple ticks going towards the right pricerange endpoint
        uint token0Transferred = 0;
        int24 tick_counter = _currentTick;

        // transfer token1 into this contract
        require(sAsset(token1).transferFrom(msg.sender, address(this), token1Amount));

        while (tick_counter <= _maxTick) {
	
            // 1. find the next initialized tick
            int24 t_s = tick_counter + int24(_tickSpacing);
            while (t_s <= _maxTick) {
                if (ticks[t_s].liquidityGross > 0) break;
                t_s += int24(_tickSpacing);
            }
	
            // 2. find root(P) at this next initialized tick
            bytes16 rootPrice_t_s_bytes = ABDKMathQuad.sqrt(exp_10001(t_s));
            uint160 rootPrice_t_s = uint160(ABDKMathQuad.toUInt(rootPrice_t_s_bytes)) + 1;

	        // 3. if delta_sqrtPrice causes global root price (the new _sqrtPriceX96) to move past this
            // next initialized tick price, then execute the trade only up to this boundary.
            if (_sqrtPriceX96 < rootPrice_t_s && ticks[t_s].liquidityGross > 0) {
                // only execute part of the swap (from sqrtPrice_mvt to rootPrice_t_s)

        		uint token0toSend = (rootPrice_t_s - sqrtPrice_mvt) * _liquidity;
                require(sAsset(token0).transfer(msg.sender, token0toSend), "failed to send chunk of token0 in transfer");
                token0Transferred += token0toSend;

                // update sqrtPrice_mvt to the price at this next initialized tick boundary
                sqrtPrice_mvt = rootPrice_t_s;

                // cross tick to the next initialized tick and continue to execute remainder of the swap
                ticks[tick_counter].feeGrowthOutside1X128 = _feeGrowthGlobal1X128 - ticks[tick_counter].feeGrowthOutside1X128;
                int128 tick_nl = ticks[t_s].liquidityNet;
                if (tick_nl > 0) _liquidity += uint128(tick_nl);
                else _liquidity -= uint128(-tick_nl);

                // move tick to the next initialized tick
                tick_counter = t_s;
            }
            else {
                // execute the whole outstanding amount within this tick and break
		        require(sAsset(token0).transfer(msg.sender, token0Amount - token0Transferred), "failed to send last chunk of token0 in transfer");
                token0Transferred += token0Amount - token0Transferred;
		        tick_counter = t_s;
		        break;
            }
        }

        // set current tick to be the final value of tick_counter
        _currentTick = tick_counter;
        require(token0Transferred == token0Amount, "failed to complete transfer correctly in amount");
    }

    // https://github.com/Uniswap/v2-core/blob/v1.0.1/contracts/libraries/Math.sol
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    // get the addresses of the tokens of this pool
    function getTokens() external view returns (address, address) {
        return (token0, token1);
    }

    // helper function to add liquidity at a position
    function addLiquidity(address sender, int24 lowerTick, int24 upperTick, uint128 liquidityDelta) internal {
        
        // update position in the mapping
        Position storage pos = positions[keccak256(abi.encodePacked(sender, lowerTick, upperTick))];
        pos.liquidity += liquidityDelta;
        // set the position's fees earned in range to the current values earned between lowerTick and upperTick range
        if (pos.liquidity == 0 && pos.feeGrowthInside0LastX128 == 0 && pos.feeGrowthInside1LastX128 == 0) {
            (pos.feeGrowthInside0LastX128, pos.feeGrowthInside1LastX128) = feesEarnedInRange(lowerTick, upperTick);
        }

        // by 6.21
        if (ticks[lowerTick].liquidityGross == 0) {
            // initialize tick by inserting the starting fees at this tick
            if (_currentTick >= lowerTick) {
                ticks[lowerTick].feeGrowthOutside0X128 = _feeGrowthGlobal0X128;
                ticks[lowerTick].feeGrowthOutside1X128 = _feeGrowthGlobal1X128;
            }
            else {
                ticks[lowerTick].feeGrowthOutside0X128 = 0;
                ticks[lowerTick].feeGrowthOutside1X128 = 0;
            }
        }
        if (ticks[upperTick].liquidityGross == 0) {
            // initialize tick by inserting the starting fees at this tick
            if (_currentTick >= upperTick) {
                ticks[upperTick].feeGrowthOutside0X128 = _feeGrowthGlobal0X128;
                ticks[upperTick].feeGrowthOutside1X128 = _feeGrowthGlobal1X128;
            }
            else {
                ticks[upperTick].feeGrowthOutside0X128 = 0;
                ticks[upperTick].feeGrowthOutside1X128 = 0;
            }
        }

        ticks[lowerTick].liquidityNet += int128(liquidityDelta);
        ticks[upperTick].liquidityNet -= int128(liquidityDelta);
        ticks[lowerTick].liquidityGross += liquidityDelta;
        ticks[upperTick].liquidityGross += liquidityDelta;

        // if price is in the range of this position, increase activated liquidity
        // increase global pool liquidity regardless
        _totalLiquidity += liquidityDelta;
        if (lowerTick <= _currentTick && _currentTick <= upperTick) {
            _liquidity += liquidityDelta;
        }

        // now calculate the amount of tokens to send according to the liquidity being added
        (uint256 token0Amount, uint256 token1Amount) = tokenAmounts(liquidityDelta, lowerTick, upperTick);

        // claim tokens from position holder
        require(sAsset(token0).transferFrom(msg.sender, address(this), token0Amount), "failed to receive token0 liquidity");
        require(sAsset(token1).transferFrom(msg.sender, address(this), token1Amount), "failed to receive token1 liquidity");
    }

    // helper function to remove liquidity at a position
    function removeLiquidity(address sender, int24 lowerTick, int24 upperTick, uint128 liquidityDelta) internal {

        // update position in the mapping
        Position storage pos = positions[keccak256(abi.encodePacked(sender, lowerTick, upperTick))];
        require(pos.liquidity - liquidityDelta >= 0, "not enough liquidity available at this position");
        pos.liquidity -= liquidityDelta;
        
        // update tick state            
        ticks[lowerTick].liquidityNet -= int128(liquidityDelta);
        ticks[upperTick].liquidityNet += int128(liquidityDelta);
        ticks[lowerTick].liquidityGross -= liquidityDelta;
        ticks[upperTick].liquidityGross -= liquidityDelta;

        // if price is in the range of this position, subtract from activated liquidity
        // subtract global pool liquidity regardless
        _totalLiquidity -= liquidityDelta;
        if (lowerTick <= _currentTick && _currentTick <= upperTick) {
            _liquidity -= liquidityDelta;
        }

        // now calculate the amount of tokens to send according to the liquidity being removed
        (uint256 token0Amount, uint256 token1Amount) = tokenAmounts(liquidityDelta, lowerTick, upperTick);

        // send tokens to position holder
        require(sAsset(token0).transfer(msg.sender, token0Amount), "failed to send token0 liquidity");
        require(sAsset(token1).transfer(msg.sender, token1Amount), "failed to send token1 liquidity");
    }

    // helper function to determine amount of tokens to send to / claim from provider when they call setPosition()
    function tokenAmounts(uint128 liquidityDelta, int24 lowerTick, int24 upperTick) internal view returns (uint256, uint256) {
        uint256 token0Amount;
        uint256 token1Amount;

        // assign token 1 amount
        if (_currentTick < lowerTick) token1Amount = 0;
        else if (lowerTick <= _currentTick && _currentTick < upperTick) {
            bytes16 sqrtPrice_lT = ABDKMathQuad.sqrt(exp_10001(lowerTick));
            uint160 priceMovement = _sqrtPriceX96 - uint160(ABDKMathQuad.toUInt(sqrtPrice_lT));
            token1Amount = liquidityDelta * priceMovement;
        }
        else {
            bytes16 sqrtPrice_lT = ABDKMathQuad.sqrt(exp_10001(lowerTick));
            bytes16 sqrtPrice_uT = ABDKMathQuad.sqrt(exp_10001(upperTick));
            uint160 priceMovement = uint160(ABDKMathQuad.toUInt(sqrtPrice_uT)) - uint160(ABDKMathQuad.toUInt(sqrtPrice_lT));
            token1Amount = liquidityDelta * priceMovement; 
        }

        // assign token 0 amount
        bytes16 one_float = ABDKMathQuad.fromUInt(1);
        if (_currentTick < lowerTick) {
            bytes16 sqrtPrice_lT_inv = ABDKMathQuad.div(one_float, ABDKMathQuad.sqrt(exp_10001(lowerTick)));
            bytes16 sqrtPrice_uT_inv = ABDKMathQuad.div(one_float, ABDKMathQuad.sqrt(exp_10001(upperTick)));
            bytes16 priceMovement = ABDKMathQuad.sub(sqrtPrice_lT_inv, sqrtPrice_uT_inv);
            bytes16 token0Amount_b = ABDKMathQuad.mul(ABDKMathQuad.fromUInt(uint256(liquidityDelta)), priceMovement);
            token0Amount = ABDKMathQuad.toUInt(token0Amount_b);
        }
        else if (lowerTick <= _currentTick && _currentTick < upperTick) {
            bytes16 sqrtPrice_uT_inv = ABDKMathQuad.div(one_float, ABDKMathQuad.sqrt(exp_10001(upperTick)));
            bytes16 sqrtPrice_inv = ABDKMathQuad.div(one_float, ABDKMathQuad.fromUInt(_sqrtPriceX96));
            bytes16 priceMovement = ABDKMathQuad.sub(sqrtPrice_inv, sqrtPrice_uT_inv);
            bytes16 token0Amount_b = ABDKMathQuad.mul(ABDKMathQuad.fromUInt(uint256(liquidityDelta)), priceMovement);
            token0Amount = ABDKMathQuad.toUInt(token0Amount_b);
        }
        else token0Amount = 0;

        // return the calculated amounts
        return (token0Amount, token1Amount);
    }

    // calculate p(i) at tick i/exp
    function exp_10001(int exp) internal pure returns (bytes16) {

        uint i;
        uint expAbs = exp >= 0 ? uint(exp) : uint(-exp);

        // set 1.0001 to start
        bytes16 one_float = ABDKMathQuad.fromInt(1);
        bytes16 ten_0000_float = ABDKMathQuad.fromInt(10000);
        bytes16 start = ABDKMathQuad.div(one_float, ten_0000_float);
        start = ABDKMathQuad.add(start, one_float);

        // raise it to |exp| power
        bytes16 res = start;
        for (i = 1; i < expAbs; i++) {
            res = ABDKMathQuad.mul(res, start);
        }

        // return the exponent
        if (exp == 0) return one_float;
        return exp > 0 ? res : ABDKMathQuad.div(one_float, res);
    }

    // helper function calculates the uncollected fees currently in this position's tick range (fees per total liquidity in pool)
    function getUncollectedFees(address sender, int24 lowerTick, int24 upperTick) internal returns (uint256, uint256) {
        Position storage pos = positions[keccak256(abi.encodePacked(sender, lowerTick, upperTick))];

        // fee growth values in lowerTick-upperTick range at the time the position was last touched (and fees were withdrawn) time 0
        uint256 fr0_t0 = pos.feeGrowthInside0LastX128;
        uint256 fr1_t0 = pos.feeGrowthInside1LastX128;

        // fee growth values now (after possible trades within the tick range of this position) time 1
        uint256 fr0_t1;
        uint256 fr1_t1;

        (fr0_t1, fr1_t1) = feesEarnedInRange(lowerTick, upperTick);

        // update position state to reflect these latest cumulative fees of its tick range and return uncollected fees
        pos.feeGrowthInside0LastX128 = fr0_t1;
        pos.feeGrowthInside1LastX128 = fr1_t1;
        return (pos.liquidity * (fr0_t1 - fr0_t0), pos.liquidity * (fr1_t1 - fr1_t0));
    }

    // return the fees per unit liquidity earned in a particular tick range
    function feesEarnedInRange(int24 lowerTick, int24 upperTick) internal view returns (uint256, uint256) {

        uint256 fr0;
        uint256 fr1;

        // first find fees earned above upper tick and fees earned below lower tick for both tokens 6.18
        uint256 fb0_lt; // fees earned below the lower tick for token 0
        uint256 fb1_lt; // fees earned below the lower tick for token 1
        uint256 fa0_ut; // fees earned above the upper tick for token 0
        uint256 fa1_ut; // fees earned above the upper tick for token 1

        // for the lower tick
        if (_currentTick >= lowerTick) {
            fb0_lt = ticks[lowerTick].feeGrowthOutside0X128;
            fb1_lt = ticks[lowerTick].feeGrowthOutside1X128;
        }
        else {
            fb0_lt = _feeGrowthGlobal0X128 - ticks[lowerTick].feeGrowthOutside0X128;
            fb1_lt = _feeGrowthGlobal1X128 - ticks[lowerTick].feeGrowthOutside1X128;
        }

        // for the upper tick
        if (_currentTick >= upperTick) {
            fa0_ut = _feeGrowthGlobal0X128 - ticks[upperTick].feeGrowthOutside0X128;
            fa1_ut = _feeGrowthGlobal1X128 - ticks[upperTick].feeGrowthOutside1X128;
        }
        else {
            fa0_ut = ticks[upperTick].feeGrowthOutside0X128;
            fa1_ut = ticks[upperTick].feeGrowthOutside1X128;
        }

        // now subtract the fees earned outside of our desired lt-ut range for both tokens 6.19
        fr0 = _feeGrowthGlobal0X128 - fb0_lt - fa0_ut;
        fr1 = _feeGrowthGlobal1X128 - fb1_lt - fa1_ut;

        return (fr0, fr1);
    }
}
