// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {CLVRMath} from "./CLVRMath.sol";


contract CLVRHook is BaseHook, CLVRMath {
    using PoolIdLibrary for PoolKey;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    struct BatchElement{ 
        IPoolManager.SwapParams params;
    }

    mapping(PoolId => BatchElement[]) public batchedSwaps;
    mapping(PoolId => uint256) private lastExecutedBatchBlock;
    mapping(PoolId => uint256) private batchStatusQuoPrice;
    mapping(PoolId => mapping(uint256 => address)) private heldBalances;

    PoolSwapTest swapRouter = PoolSwapTest(address(0x01));

    // Number of blocks between batched executions
    uint32 public CLVR_EXECUTION_PERIOD;

    bytes private ZERO_BYTES = bytes("");

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {

        if (params.amountSpecified < 0) {
            // take the input token so that v3-swap is skipped...
            uint256 amountTaken = uint256(-params.amountSpecified);
            Currency input = params.zeroForOne ? key.currency0 : key.currency1;
            poolManager.mint(address(this), input.toId(), amountTaken);

            // Batch the swap
            if (block.number - lastExecutedBatchBlock[key.toId()] < CLVR_EXECUTION_PERIOD) {
                batchedSwaps[key.toId()].push(BatchElement(params));

                // Transfer the taken amount from the sender
                IERC20Minimal(params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
                    .transferFrom(sender, address(this), amountTaken);

                mapping(uint256 => address) storage balances = heldBalances[key.toId()];
                balances[amountTaken] = sender;
            } else {    // Execute the batched swaps
                executeBatchedSwaps(key);
            }

            // to NoOp the exact input, we return the amount that's taken by the hook
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(uint256Toint128(amountTaken), 0), 0);
        }

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }

    function executeBatchedSwaps(PoolKey memory key) internal {
        BatchElement[] memory batch = batchedSwaps[key.toId()];

        for (uint256 i = 0; i < batch.length; i++) {
            IPoolManager.SwapParams memory params = batch[i].params;
            
            PoolSwapTest.TestSettings memory testSettings =
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

            BalanceDelta delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
            mapping(uint256 => address) storage balances = heldBalances[key.toId()];

            if (params.zeroForOne) {
                if (delta.amount0() < 0) {
                    poolManager.settle();
                }

                if (delta.amount1() > 0) {
                    uint256 amount = int128Touint256(delta.amount1());
                    poolManager.take(key.currency1, address(balances[amount]), amount);
                }
            } else {
                if (delta.amount1() < 0) {
                    poolManager.settle();
                }

                if (delta.amount0() > 0) {
                    uint256 amount = int128Touint256(delta.amount0());
                    poolManager.take(key.currency0, address(balances[amount]), amount);
                }
            }
        }
    }

    function uint256Toint128(uint256 x) internal pure returns (int128) {
        require(x <= uint256(uint128(type(int128).max)), "CLVRHook: uint256 out of bounds");
        return int128(uint128(x));
    }

    function int128Touint256(int128 x) internal pure returns (uint256) {
        return uint256(uint128(x));
    }
}
