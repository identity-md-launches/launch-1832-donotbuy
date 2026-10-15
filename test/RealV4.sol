// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "../lib/v4-core/src/PoolManager.sol";
import {IPoolManager as V4Manager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey as V4Key} from "../lib/v4-core/src/types/PoolKey.sol";
import {PoolId} from "../lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "../lib/v4-core/src/libraries/StateLibrary.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    ModifyLiquidityParams,
    SwapParams,
    IERC20Min
} from "../src/interfaces/Interfaces.sol";

/// @notice Test router for real v4 operations. No substituted pool math or storage writes.
contract V4Router is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }
    receive() external payable {}

    function donate(PoolKey memory key, uint256 ethAmount, uint256 tokenAmount) external {
        manager.unlock(abi.encode(uint8(0), key, ethAmount, tokenAmount));
    }

    function add(PoolKey memory key, uint256 liquidity) external {
        manager.unlock(abi.encode(uint8(1), key, liquidity, uint256(0)));
    }

    function remove(PoolKey memory key, uint256 liquidity) external {
        manager.unlock(abi.encode(uint8(4), key, liquidity, uint256(0)));
    }

    function trade(PoolKey memory key, bool zeroForOne, uint256 amount) external returns (int256) {
        return abi.decode(manager.unlock(abi.encode(uint8(zeroForOne ? 2 : 3), key, amount, uint256(0))), (int256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, PoolKey memory key, uint256 a, uint256 b) = abi.decode(data, (uint8, PoolKey, uint256, uint256));
        int256 d;
        if (action == 0) {
            V4Key memory vkey = abi.decode(abi.encode(key), (V4Key));
            d = int256(BalanceDelta.unwrap(V4Manager(address(manager)).donate(vkey, a, b, "")));
        } else if (action == 1 || action == 4) {
            (d,) = manager.modifyLiquidity(
                key, ModifyLiquidityParams(-887200, 887200, action == 1 ? int256(a) : -int256(a), 0), ""
            );
        } else {
            bool direction = action == 2;
            d = manager.swap(
                key,
                SwapParams(
                    direction, -int256(a), direction ? 4295128740 : 1461446703485210103287273052203988822378723970341
                ),
                ""
            );
        }
        _settle(key.currency0, int128(d >> 128));
        _settle(key.currency1, int128(d));
        return abi.encode(d);
    }

    function _settle(address currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(uint128(-delta));
            if (currency == address(0)) {
                manager.sync(address(0));
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                require(IERC20Min(currency).transfer(address(manager), amount));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }
}
import {BalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
