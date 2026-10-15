// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadErrors} from "./interfaces/PadErrors.sol";

import {PadLib} from "./libs/PadLib.sol";
import {IPvPPad, IPadLiquidity} from "./interfaces/Interfaces.sol";

interface IPadFund {
    function fundGames() external payable;
}

/// @title KingOfThePad
/// @notice Crown auction. Opens after PvP graduates. Last contract in the manifest: its constructor
/// binds to the pad and PadLiquidity; opening the pad later creates genesis.
contract KingOfThePad {
    /// @notice Minimum settlement stipend a bid must carry. Everything the bidder supplies beyond the
    /// outer reserve is forwarded, so more pools settle when more gas is sent.
    uint256 public constant CROWN_DISTRIBUTE_GAS = 5_000_000;
    uint256 public constant MIN_BID = 0.01 ether;
    uint256 public constant HOLD = 1 hours;
    uint256 public constant STEP_BPS = 11_000;
    uint256 internal constant CROWN_RESERVE_GAS = 600_000;

    IPvPPad public immutable pad;
    IPadLiquidity public immutable liquidity;
    address public immutable dev;

    address public king;
    uint256 public bid;
    uint64 public crownedAt;
    uint256 public crownCount;
    bool private locked;
    mapping(address => uint256) public claimable;

    event Crowned(address indexed king, address indexed previous, uint256 bid, uint256 extra, uint256 refund);
    event ExtraSplit(uint256 games, uint256 burn, uint256 dev);
    event Refunded(address indexed to, uint256 amount, bool pushed);
    event Claimed(address indexed to, uint256 amount);

    modifier guard() {
        if (!(!locked)) revert PadErrors.PadReentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor(address pad_, address liquidity_, address dev_) {
        if (!(pad_ != address(0) && liquidity_ != address(0) && dev_ != address(0))) revert PadErrors.PadZero();
        pad = IPvPPad(pad_);
        liquidity = IPadLiquidity(liquidity_);
        dev = dev_;
        IPadLiquidity(liquidity_).bindKing();
        IPvPPad(pad_).startGenesis();
    }

    function owner() external view returns (address) {
        return dev;
    }

    /// @notice First bid >= 0.01 ETH, then >= 110% of the current bid once the king has held 1 hour.
    function takeCrown() external payable guard {
        if (!(pad.genesisGraduated())) revert PadErrors.PadKingNotOpen();
        liquidity.requireManagerLocked();
        address previous = king;
        uint256 previousBid = bid;
        uint256 extra;
        if (previous == address(0)) {
            if (!(msg.value >= MIN_BID)) revert PadErrors.PadMinBid();
            extra = msg.value;
        } else {
            if (!(block.timestamp >= crownedAt + HOLD)) revert PadErrors.PadKingHolds();
            if (!(msg.value >= previousBid * STEP_BPS / 10_000)) revert PadErrors.PadBidTooLow();
            extra = msg.value - previousBid;
        }
        // Forward at least the minimum stipend despite EIP-150, and every unit of gas the bidder
        // supplied beyond the outer reserve, so the settlement covers as many pools as the bid pays
        // for. Every unflagged pool it reaches must settle; errors (including OOG) abort the bid.
        if (previous != address(0)) {
            uint256 available = gasleft();
            if (!(available >= CROWN_DISTRIBUTE_GAS + CROWN_DISTRIBUTE_GAS / 63 + CROWN_RESERVE_GAS)) {
                revert PadErrors.PadSettlementGas();
            }
            liquidity.settleCrown{gas: available - CROWN_RESERVE_GAS}();
        }
        king = msg.sender;
        bid = msg.value;
        crownedAt = uint64(block.timestamp);
        crownCount += 1;
        emit Crowned(msg.sender, previous, msg.value, extra, previousBid);
        if (previousBid != 0) {
            bool ok = PadLib.push(previous, previousBid);
            if (!ok) claimable[previous] += previousBid;
            emit Refunded(previous, previousBid, ok);
        }
        uint256 games = extra / 2;
        uint256 burn = extra / 4;
        uint256 devShare = extra - games - burn;
        if (games != 0) IPadFund(address(pad)).fundGames{value: games}();
        if (burn != 0) liquidity.fundBurn{value: burn}();
        if (devShare != 0) {
            bool okDev = PadLib.push(dev, devShare);
            if (!okDev) claimable[dev] += devShare;
        }
        emit ExtraSplit(games, burn, devShare);
        pad.upkeepFor(msg.sender); // upkeep fees (finalizer) go to the bidder, not to this contract
    }

    /// @notice Collect LP fees in kind from at most 16 of the next n graduated pools and pay the king
    /// each pool is owed to (the current king, or an earlier one whose reign the pool was never settled for).
    function distribute(uint256 n) external {
        liquidity.distribute(n);
    }

    function claim() external guard {
        uint256 amount = claimable[msg.sender];
        if (!(amount != 0)) revert PadErrors.PadNothing();
        claimable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!(ok)) revert PadErrors.PadClaimFailed();
        emit Claimed(msg.sender, amount);
    }

    function nextMinBid() external view returns (uint256) {
        return king == address(0) ? MIN_BID : bid * STEP_BPS / 10_000;
    }

    function challengeOpensAt() external view returns (uint256) {
        return king == address(0) ? 0 : crownedAt + HOLD;
    }
}
