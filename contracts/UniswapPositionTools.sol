// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import "hardhat/console.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/libraries/TickMath.sol';
import '@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol';
import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import './interfaces/IUniswapPositionTools.sol';

/// @notice how reward should be converted
enum RewardConversion { NONE, TOKEN_0, TOKEN_1 }

contract UniswapPositionTools is IUniswapPositionTools, ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    uint128 constant Q64 = 2**64;
    uint128 constant Q96 = 2**96;

    // max reward
    uint64 constant public MAX_REWARD_X64 = uint64(Q64 / 50); // 2%
    // changable config values
    uint32 public override maxTWAPTickDifference = 100; // 1%
    uint32 public override TWAPSeconds = 60;

    // wrapped native token address
    address override public weth;
    // uniswap v3 components
    IUniswapV3Factory public override factory;
    INonfungiblePositionManager public override nonfungiblePositionManager;
    ISwapRouter public override swapRouter;

    constructor(
        address _weth,
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        ISwapRouter _swapRouter
    ) {
        weth = _weth;
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        swapRouter = _swapRouter;
    }

    // state used during autocompound execution
    struct CompoundState {
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amount0Fees;
        uint256 amount1Fees;
        uint256 priceX96;
        address tokenOwner;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
    }

    function swapAndCompound(
        uint256 tokenId
    ) override external nonReentrant returns (
        uint256 compounded0, uint256 compounded1
    ) {
        CompoundState memory state;
        // collect fees
        (state.amount0, state.amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                tokenId, address(this), type(uint128).max, type(uint128).max
            )
        );

        // only if there are balances to work with - start autocompounding process
        if (state.amount0 > 0 || state.amount1 > 0) {
            // get position info
            (
                ,, state.token0, state.token1, state.fee,
                state.tickLower, state.tickUpper,,,,,
            ) = nonfungiblePositionManager.positions(tokenId);

            // checks oracle for fair price - swaps to position ratio (considering estimated reward) - calculates max amount to be added
            (
                state.amount0, state.amount1, state.priceX96
            ) = _swapToPriceRatio(SwapParams(
                state.token0,
                state.token1,
                state.fee,
                state.tickLower,
                state.tickUpper,
                state.amount0,
                state.amount1,
                block.timestamp,
                true
            ));

            // approve tokens for nonfungiblePositionManager
            SafeERC20.safeIncreaseAllowance(
                IERC20(state.token0), address(nonfungiblePositionManager), state.amount0
            );
            SafeERC20.safeIncreaseAllowance(
                IERC20(state.token1), address(nonfungiblePositionManager), state.amount1
            );
            // deposit liquidity into tokenId
            (, compounded0, compounded1) = nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    tokenId,
                    state.amount0,
                    state.amount1,
                    0,
                    0,
                    block.timestamp
                )
            );

            // calculate and transfer remaining tokens for owner
            //SafeERC20.safeTransfer(IERC20(state.token0), state.tokenOwner, state.amount0.sub(compounded0).sub(state.amount0Fees));
            //SafeERC20.safeTransfer(IERC20(state.token1), state.tokenOwner, state.amount1.sub(compounded1).sub(state.amount1Fees));
        }
    }

    function remint(
        uint256 tokenId, int24 tickLower, int24 tickUpper
    ) override external returns (
        uint256 newTokenId, uint256 amount0, uint256 amount1
    ) {
        CompoundState memory state;
        // get position info
        uint128 liquidity;
        (, , state.token0, state.token1, state.fee, , , liquidity, , , , ) =
            nonfungiblePositionManager.positions(tokenId);

        // remove liquidity
        (state.amount0, state.amount1) = nonfungiblePositionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams(
                tokenId, liquidity, 0, 0, block.timestamp
            )
        );
        // collect fees
        nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                tokenId, address(this), type(uint128).max, type(uint128).max
            )
        );
        // checks oracle for fair price - swaps to position ratio (considering estimated reward) - calculates max amount to be added
        (
            state.amount0, state.amount1, state.priceX96
        ) = _swapToPriceRatio(SwapParams(
            state.token0,
            state.token1,
            state.fee,
            tickLower,
            tickUpper,
            state.amount0,
            state.amount1,
            block.timestamp,
            true
        ));

        // approve tokens for nonfungiblePositionManager
        SafeERC20.safeIncreaseAllowance(
            IERC20(state.token0), address(nonfungiblePositionManager), state.amount0
        );
        SafeERC20.safeIncreaseAllowance(
            IERC20(state.token1), address(nonfungiblePositionManager), state.amount1
        );

        // mint new position
        (
            newTokenId, , amount0, amount1
        ) = nonfungiblePositionManager.mint(INonfungiblePositionManager.MintParams(
            state.token0, state.token1, state.fee,
            tickLower, tickUpper,
            state.amount0, state.amount1,
            0, 0,
            msg.sender,
            block.timestamp
        ));

        // calculate and transfer remaining tokens for owner
        SafeERC20.safeTransfer(IERC20(state.token0), msg.sender, state.amount0.sub(amount0));
        SafeERC20.safeTransfer(IERC20(state.token1), msg.sender, state.amount1.sub(amount1));
    }

    function removeLiquidityAndSwap(
        uint256 tokenId, uint128 liquidityAmount, RewardConversion conversion
    ) override external returns (
        uint256 amount0, uint256 amount1
    ) {
        // get postion info
        (
            ,,address token0, address token1, uint24 fee,,,uint128 liquidity,,,,
        ) = nonfungiblePositionManager.positions(tokenId);
        // calc liquidity percent
        if(liquidityAmount == 0) liquidityAmount = liquidity;
        // close position and calc total token amount
        // remove liquidity
        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityAmount,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // collect fees
        nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                tokenId, address(this),
                type(uint128).max, type(uint128).max
            )
        );

        // swap to requested token
        if (conversion == RewardConversion.TOKEN_0) {
            // swap token1 to token0
            SafeERC20.safeIncreaseAllowance(
                IERC20(token1), address(swapRouter), amount1
            );
            amount0 += swapRouter.exactInput(
                ISwapRouter.ExactInputParams(
                    abi.encodePacked(token1, fee, token0),
                    msg.sender,
                    block.timestamp,
                    amount1,
                    0
                )
            );
            amount1 = 0;
        } else if(conversion == RewardConversion.TOKEN_1) {
            // swap token0 to token1
            SafeERC20.safeIncreaseAllowance(
                IERC20(token0), address(swapRouter), amount0
            );
            amount1 += swapRouter.exactInput(
                ISwapRouter.ExactInputParams(
                    abi.encodePacked(token0, fee, token1),
                    msg.sender,
                    block.timestamp,
                    amount0,
                    0
                )
            );
            amount0 = 0;
        } else {
            if(amount0 > 0) TransferHelper.safeTransfer(token0, msg.sender, amount0);
            if(amount1 > 0) TransferHelper.safeTransfer(token1, msg.sender, amount1);    
        }

        nonfungiblePositionManager.burn(tokenId);
    }

    //
    // adapted from https://github.com/revert-finance/compoundor/blob/main/contracts/Compoundor.sol
    //
    /**
     * @notice Management method to change the max tick difference from twap to allow swaps (onlyOwner)
     * @param _maxTWAPTickDifference new max tick difference
     */
    function setTWAPConfig(uint32 _maxTWAPTickDifference, uint32 _TWAPSeconds) external override onlyOwner {
        maxTWAPTickDifference = _maxTWAPTickDifference;
        TWAPSeconds = _TWAPSeconds;
        emit TWAPConfigUpdated(msg.sender, _maxTWAPTickDifference, _TWAPSeconds);
    }

    function _getTWAPTick(IUniswapV3Pool pool, uint32 twapPeriod) internal view returns (int24, bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 0; // from (before)
        secondsAgos[1] = twapPeriod; // from (before)
        // pool observe may fail when there is not enough history available
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            return (int24((tickCumulatives[0] - tickCumulatives[1]) / twapPeriod), true);
        } catch {
            return (0, false);
        }
    }

    function _requireMaxTickDifference(int24 tick, int24 other, uint32 maxDifference) internal pure {
        require(other > tick && (uint48(other - tick) < maxDifference) ||
        other <= tick && (uint48(tick - other) < maxDifference),
        "price err");
    }

    // state used during swap execution
    struct SwapState {
        uint256 rewardAmount0;
        uint256 rewardAmount1;
        uint256 positionAmount0;
        uint256 positionAmount1;
        int24 tick;
        int24 otherTick;
        uint160 sqrtPriceX96;
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
        uint256 amountRatioX96;
        uint256 delta0;
        uint256 delta1;
        bool sell0;
        bool twapOk;
    }

    struct SwapParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint256 deadline;
        bool doSwap;
    }

    // checks oracle for fair price - swaps to position ratio - calculates max amount to be added
    function _swapToPriceRatio(SwapParams memory params) internal returns (
        uint256 amount0, uint256 amount1, uint256 priceX96
    ) {
        SwapState memory state;

        amount0 = params.amount0;
        amount1 = params.amount1;

        // aprove tokens for swapRouter
        SafeERC20.safeIncreaseAllowance(
            IERC20(params.token0), address(swapRouter), params.amount0
        );
        SafeERC20.safeIncreaseAllowance(
            IERC20(params.token1), address(swapRouter), params.amount1
        );

        // get price
        IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(params.token0, params.token1, params.fee));

        (state.sqrtPriceX96,state.tick,,,,,) = pool.slot0();

        // how many seconds are needed for TWAP protection
        uint32 tSecs = TWAPSeconds;
        if (tSecs > 0) {
            // check that price is not too far from TWAP (protect from price manipulation attacks)
            (state.otherTick, state.twapOk) = _getTWAPTick(pool, tSecs);
            if (state.twapOk) {
                _requireMaxTickDifference(state.tick, state.otherTick, maxTWAPTickDifference);
            } else {
                // if there is no valid TWAP - disable swap
                params.doSwap = false;
            }
        }

        priceX96 = uint256(state.sqrtPriceX96).mul(state.sqrtPriceX96).div(Q96);

        // swap to correct proportions is requested
        if (params.doSwap) {

            // calculate ideal position amounts
            state.sqrtPriceX96Lower = TickMath.getSqrtRatioAtTick(params.tickLower);
            state.sqrtPriceX96Upper = TickMath.getSqrtRatioAtTick(params.tickUpper);
            (state.positionAmount0, state.positionAmount1) = LiquidityAmounts.getAmountsForLiquidity(
                                                                state.sqrtPriceX96,
                                                                state.sqrtPriceX96Lower,
                                                                state.sqrtPriceX96Upper,
                                                                Q96); // dummy value we just need ratio

            // calculate how much of the position needs to be converted to the other token
            if (state.positionAmount0 == 0) {
                state.delta0 = amount0;
                state.sell0 = true;
            } else if (state.positionAmount1 == 0) {
                state.delta0 = amount1.mul(Q96).div(priceX96);
                state.sell0 = false;
            } else {
                state.amountRatioX96 = state.positionAmount0.mul(Q96).div(state.positionAmount1);
                state.sell0 = (state.amountRatioX96.mul(amount1) < amount0.mul(Q96));
                if (state.sell0) {
                    state.delta0 = amount0.mul(Q96).sub(state.amountRatioX96.mul(amount1)).div(state.amountRatioX96.mul(priceX96).div(Q96).add(Q96));
                } else {
                    state.delta0 = state.amountRatioX96.mul(amount1).sub(amount0.mul(Q96)).div(state.amountRatioX96.mul(priceX96).div(Q96).add(Q96));
                }
            }

            if (state.delta0 > 0) {
                if (state.sell0) {
                    uint256 amountOut = _swap(
                        abi.encodePacked(params.token0, params.fee, params.token1),
                        state.delta0,
                        params.deadline
                    );
                    amount0 = amount0.sub(state.delta0);
                    amount1 = amount1.add(amountOut);
                } else {
                    state.delta1 = state.delta0.mul(priceX96).div(Q96);
                    // prevent possible rounding to 0 issue
                    if (state.delta1 > 0) {
                        uint256 amountOut = _swap(abi.encodePacked(params.token1, params.fee, params.token0), state.delta1, params.deadline);
                        amount0 = amount0.add(amountOut);
                        amount1 = amount1.sub(state.delta1);
                    }
                }
            }
        }
    }

    function _swap(
        bytes memory swapPath, uint256 amount, uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (amount > 0) {
            amountOut = swapRouter.exactInput(
                ISwapRouter.ExactInputParams(
                    swapPath, address(this), deadline, amount, 0
                )
            );
        }
    }
}