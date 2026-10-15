// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Test stand-in for the ArbSys precompile at 0x64. Block number is set by tests; hashes are
/// deterministic from the block number and only served inside the 256-block window, as on Arbitrum.
contract MockArbSys {
    uint256 public number = 1000;

    function set(uint256 n) external {
        number = n;
    }

    function advance(uint256 n) external {
        number += n;
    }

    function arbBlockNumber() external view returns (uint256) {
        return number;
    }

    function arbBlockHash(uint256 n) external view returns (bytes32) {
        require(n < number && n + 256 >= number, "invalid block number");
        return keccak256(abi.encode("arb", n));
    }
}

/// @notice Receiver that rejects ETH, to exercise the claimable fallback.
contract Rejector {
    receive() external payable {
        revert("no");
    }
}
