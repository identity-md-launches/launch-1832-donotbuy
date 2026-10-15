// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadErrors} from "./interfaces/PadErrors.sol";

import {PadLib} from "./libs/PadLib.sol";
import {IPadToken, IPadGame, IPadLiquidity} from "./interfaces/Interfaces.sol";

/// @title PvPPad
/// @notice Registry, clone factory, carry pot and open switch of the PvP Pad.
contract PvPPad {
    uint256 public constant OPEN_DELAY = 30 days;
    uint256 public constant MAX_NAME = 32;
    uint256 public constant MAX_TICKER = 10;
    uint256 public constant MAX_URL = 200;
    uint256 public constant KING_MAX_GAMES = 10;
    uint256 public constant KING_MIN_IMPS = 5;
    uint256 internal constant UPKEEP_STEP_GAS = 4_500_000;
    uint256 internal constant UPKEEP_DISTRIBUTE_GAS = 750_000;
    uint256 internal constant UPKEEP_BURN_GAS = 350_000;
    uint256 internal constant UPKEEP_OBSERVE_GAS = 80_000;
    uint256 internal constant UPKEEP_RESERVE_GAS = 100_000;
    string internal constant GENESIS_NAME = "Pepes Value Pepes";
    string internal constant GENESIS_TICKER = "PVP";
    uint160 internal constant HOOK_MASK = (1 << 14) - 1;
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;

    struct Launch {
        address token;
        address game;
        address creator;
        uint64 createdAt;
        string name;
        string ticker;
        string imageURL;
    }

    address public immutable owner;
    address public immutable tokenTemplate;
    address public immutable gameTemplate;
    uint64 public immutable deployedAt;

    address public liquidity;
    address public king;
    bool public opened;
    bytes32 public openSalt;
    address public hook;
    uint256 public carryPot;
    uint256 public upkeepCursor;
    /// @notice Launch id of the current genesis (PvP). A failed genesis is replaced by a new one.
    uint256 public genesisId;
    bool private locked;

    Launch[] internal launches;
    mapping(address => bool) public isGame;
    /// @dev Launch ids in order of first paid entry; the king's window and upkeep walk this list.
    uint256[] internal entered;

    event LiquidityBound(address indexed liquidity);
    event KingBound(address indexed king);
    event Opened(address indexed by, bytes32 salt, address hook);
    event Launched(
        uint256 indexed id, address indexed token, address indexed game, address creator, string name, string ticker
    );
    event CarryFunded(address indexed from, uint256 amount);
    event CarryPaid(uint256 indexed id, uint256 amount);
    event SignupStarted(uint256 indexed id);
    event GamesFunded(uint256 amount, uint256 games);
    event GenesisRestarted(uint256 indexed id, uint256 indexed failedId, address indexed by);

    constructor(address owner_, address tokenTemplate_, address gameTemplate_) {
        if (!(owner_ != address(0) && tokenTemplate_ != address(0) && gameTemplate_ != address(0))) {
            revert PadErrors.PadZero();
        }
        owner = owner_;
        tokenTemplate = tokenTemplate_;
        gameTemplate = gameTemplate_;
        deployedAt = uint64(block.timestamp);
    }

    // ---- one-shot bindings from later constructors --------------------------------------------
    function bindLiquidity() external {
        if (!(liquidity == address(0))) revert PadErrors.PadBound();
        liquidity = msg.sender;
        emit LiquidityBound(msg.sender);
    }

    /// @notice Called once by KingOfThePad's constructor: binds the king contract. Genesis waits for openPad.
    function startGenesis() external {
        if (!(king == address(0))) revert PadErrors.PadBound();
        if (!(liquidity != address(0))) revert PadErrors.PadNoLiquidity();
        king = msg.sender;
        emit KingBound(msg.sender);
    }

    /// @notice A genesis game that ended with no net curve ETH (no roll, or every roll's coins bailed
    /// out back to the curve) is marked failed and its token burned.
    /// Anyone may then relaunch PvP so the pad is never locked: the new launch becomes the genesis
    /// that other launches, the king and the burn wait for. `launch()` does the same when it finds
    /// the genesis failed.
    function restartGenesis() public returns (uint256 id) {
        if (!(opened)) revert PadErrors.PadPadNotOpen();
        if (!(genesisFailed())) revert PadErrors.PadGenesisNotFailed();
        uint256 failedId = genesisId;
        id = _create(GENESIS_NAME, GENESIS_TICKER, "", owner, true);
        genesisId = id;
        emit GenesisRestarted(id, failedId, msg.sender);
    }

    // ---- open switch ---------------------------------------------------------------------------
    /// @notice Opens the pad once: by the owner, or by anyone 30 days after deployment. Deploys PadHook
    /// through PadLiquidity with `salt`; reverts unless the hook address carries exactly the
    /// beforeInitialize flag. The pad then creates the genesis token and game; deployment minted none.
    function openPad(bytes32 salt) external {
        if (!(!opened)) revert PadErrors.PadOpened();
        if (!(msg.sender == owner || block.timestamp >= deployedAt + OPEN_DELAY)) revert PadErrors.PadNotYet();
        if (!(liquidity != address(0) && king != address(0))) revert PadErrors.PadNotBound();
        opened = true;
        openSalt = salt;
        address h = IPadLiquidity(liquidity).deployHook(salt);
        if (!(uint160(h) & HOOK_MASK == BEFORE_INITIALIZE_FLAG)) revert PadErrors.PadHookFlags();
        hook = h;
        emit Opened(msg.sender, salt, h);
        genesisId = _create(GENESIS_NAME, GENESIS_TICKER, "", owner, true);
    }

    // ---- launches --------------------------------------------------------------------------------
    /// @notice Creates a launch once PvP has graduated. If the current genesis failed (ended with no
    /// roll), the call relaunches PvP instead and returns the new genesis id; the requested launch is
    /// not created until that genesis graduates. Check `genesisGraduated()` / `genesisFailed()` first.
    function launch(string calldata name, string calldata ticker, string calldata imageURL)
        external
        returns (uint256 id)
    {
        if (!(opened)) revert PadErrors.PadPadNotOpen();
        if (!(bytes(name).length != 0 && bytes(name).length <= MAX_NAME)) revert PadErrors.PadName();
        if (!(bytes(ticker).length != 0 && bytes(ticker).length <= MAX_TICKER)) revert PadErrors.PadTicker();
        if (!(bytes(imageURL).length <= MAX_URL)) revert PadErrors.PadUrl();
        if (genesisFailed()) {
            id = restartGenesis();
        } else {
            if (!(genesisGraduated())) revert PadErrors.PadGenesisNotGraduated();
            id = _create(name, ticker, imageURL, msg.sender, false);
        }
        upkeep();
    }

    function _create(string memory name, string memory ticker, string memory url, address creator, bool genesis)
        internal
        returns (uint256 id)
    {
        address token = PadLib.clone(tokenTemplate);
        address game = PadLib.clone(gameTemplate);
        id = launches.length + 1;
        launches.push(Launch(token, game, creator, uint64(block.timestamp), name, ticker, url));
        isGame[game] = true;
        IPadToken(token).initialize(name, ticker, game, liquidity);
        IPadGame(game).initialize(id, token, liquidity, genesis);
        emit Launched(id, token, game, creator, name, ticker);
    }

    /// @notice A game reports its first paid entry once. Only entered launches take part in upkeep
    /// and in the king's last-10 window, so a free launch nobody enters cannot crowd them out.
    function noteFirstEntry(uint256 id) external {
        _onlyGame(id);
        entered.push(id);
        emit SignupStarted(id);
    }

    // ---- pots ------------------------------------------------------------------------------------
    /// @notice Permissionless donation; anyone may fund carry. Donations never bypass release caps.
    function fundCarry() external payable {
        carryPot += msg.value;
        emit CarryFunded(msg.sender, msg.value);
    }

    /// @notice A registered game pulls only its unused funded-release allowance at finalization.
    /// The immutable game computes the allowance after counting at least five living Imps.
    function takeCarry(uint256 id, uint256 maxAmount) external {
        _onlyGame(id);
        uint256 carry = carryPot < maxAmount ? carryPot : maxAmount;
        if (carry == 0) return;
        carryPot -= carry;
        IPadGame(msg.sender).fundPot{value: carry}();
        emit CarryPaid(id, carry);
    }

    /// @notice King's 50% share: live games with >= 5 entries before drawing or Imps after drawing,
    /// among the last 10 entered launches, weighted
    /// by roll-earned pot size (equal split when every pot is empty); none live: carry pot. Each game
    /// pays funded ETH out only with >= 5 living Imps at its end, at most 3x its roll-earned pot and
    /// at most 15% of its curve ETH; the rest returns here as carry.
    function fundGames() external payable {
        if (!(msg.sender == king)) revert PadErrors.PadNotKing();
        uint256 n = entered.length;
        uint256 from = n > KING_MAX_GAMES ? n - KING_MAX_GAMES : 0;
        address[] memory games = new address[](n - from);
        uint256[] memory pots = new uint256[](n - from);
        uint256 count;
        uint256 total;
        for (uint256 i = from; i < n; ++i) {
            address game = launches[entered[i] - 1].game;
            (bool live, uint256 p) = IPadGame(game).isLiveForKing();
            if (!live) continue;
            games[count] = game;
            pots[count] = p;
            total += p;
            ++count;
        }
        if (count == 0) {
            carryPot += msg.value;
            emit CarryFunded(msg.sender, msg.value);
            return;
        }
        uint256 sent;
        for (uint256 i; i < count; ++i) {
            uint256 share = total == 0 ? msg.value / count : msg.value * pots[i] / total;
            if (i == count - 1) share = msg.value - sent;
            sent += share;
            if (share != 0) IPadGame(games[i]).fundPot{value: share}();
        }
        emit GamesFunded(msg.value, count);
    }

    // ---- upkeep ----------------------------------------------------------------------------------
    /// @notice Bounded upkeep: one IMD/ETH spot observation for the conversion anchor, the latest
    /// entered game, one older entered game (round-robin), two pools, one burn chunk. Launches
    /// without an entry have nothing to tend.
    function upkeep() public {
        _upkeep(msg.sender);
    }

    /// @notice Games and the king contract call this so the finalizer fee of upkeep work goes to their
    /// caller, not to the contract.
    function upkeepFor(address caller) external {
        if (!(isGame[msg.sender] || msg.sender == king)) revert PadErrors.PadNotGame();
        _upkeep(caller);
    }

    function _upkeep(address caller) internal {
        if (locked || gasleft() < UPKEEP_RESERVE_GAS + 50_000) return;
        locked = true;
        // Every pad touch records the venue spot, so the conversion anchor a finalization uses was
        // set by the whole game's activity, not by whoever finalizes. Capped; the reserve check
        // above leaves room for it, and later steps re-check their own budgets.
        try IPadLiquidity(liquidity).observeMarket{gas: UPKEEP_OBSERVE_GAS}() {} catch {}
        uint256 n = entered.length;
        if (n != 0) {
            _tend(launches[entered[n - 1] - 1].game, caller);
            if (n > 1) {
                uint256 c = upkeepCursor % (n - 1);
                upkeepCursor = c + 1;
                _tend(launches[entered[c] - 1].game, caller);
            }
        }
        if (launches.length != 0) {
            if (_canSpend(UPKEEP_DISTRIBUTE_GAS)) {
                try IPadLiquidity(liquidity).distribute{gas: UPKEEP_DISTRIBUTE_GAS}(2) {} catch {}
            }
            if (_canSpend(UPKEEP_BURN_GAS)) {
                try IPadLiquidity(liquidity).burnChunk{gas: UPKEEP_BURN_GAS}() {} catch {}
            }
        }
        locked = false;
    }

    function _tend(address game, address caller) internal {
        if (_canSpend(UPKEEP_STEP_GAS)) {
            try IPadGame(game).upkeepStep{gas: UPKEEP_STEP_GAS}(caller) {} catch {}
        }
    }

    function _canSpend(uint256 cap) internal view returns (bool) {
        return gasleft() >= cap + cap / 63 + UPKEEP_RESERVE_GAS;
    }

    // ---- views -----------------------------------------------------------------------------------
    function genesisGraduated() public view returns (bool) {
        if (genesisId == 0) return false;
        IPadGame g = IPadGame(launches[genesisId - 1].game);
        return g.graduated() && !g.failed();
    }

    function genesisFailed() public view returns (bool) {
        if (genesisId == 0) return false;
        return IPadGame(launches[genesisId - 1].game).failed();
    }

    function _onlyGame(uint256 id) internal view {
        if (!(launches[id - 1].game == msg.sender)) revert PadErrors.PadNotGame();
    }

    function launchCount() external view returns (uint256) {
        return launches.length;
    }

    /// @notice Number of launches that received a first entry, and the launch id at that position.
    function enteredCount() external view returns (uint256) {
        return entered.length;
    }

    function enteredAt(uint256 i) external view returns (uint256) {
        return entered[i];
    }

    function getLaunch(uint256 id) external view returns (Launch memory) {
        return launches[id - 1];
    }

    function gameOf(uint256 id) external view returns (address) {
        return launches[id - 1].game;
    }

    function tokenOf(uint256 id) external view returns (address) {
        return launches[id - 1].token;
    }

    function openDeadline() external view returns (uint256) {
        return deployedAt + OPEN_DELAY;
    }
}
