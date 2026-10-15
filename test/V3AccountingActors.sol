// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev A test recipient whose ETH receipts can be independently reconciled with protocol debts.
/// Only one storage write in receive: an accepting recipient fits the protocol's 30k push budget.
contract AccountingRecipient {
    bool public rejecting;
    uint256 public received;

    function setRejecting(bool value) external {
        rejecting = value;
    }

    receive() external payable {
        require(!rejecting, "recipient rejects ETH");
        received += msg.value;
    }
}
