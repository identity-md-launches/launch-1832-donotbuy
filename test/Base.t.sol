// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PadToken} from "../src/PadToken.sol";
import {PadGame} from "../src/PadGame.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {PadHook} from "../src/PadHook.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {MockArbSys, Rejector} from "./mocks/Mocks.sol";
import {PoolManager, V4Router, V4Manager, StateLibrary, PoolId} from "./RealV4.sol";
import {IPoolManager, PoolKey} from "../src/interfaces/Interfaces.sol";

/// @notice Deploys the five manifest contracts in order inside one call, as the factory does.
contract OneShotDeployer {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    PadToken public token;
    PadGame public game;
    PvPPad public pad;
    PadLiquidity public liquidity;
    KingOfThePad public king;
    uint256 public gasUsed;

    function deployAll(address owner, address poolManager) external {
        uint256 g = gasleft();
        token = new PadToken();
        game = new PadGame();
        pad = new PvPPad(owner, address(token), address(game));
        liquidity = new PadLiquidity(
            poolManager, address(pad), IMD, 0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02
        );
        king = new KingOfThePad(address(pad), address(liquidity), owner);
        gasUsed = g - gasleft();
    }
}

abstract contract BaseTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant OWNER = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address constant ARB_ADDR = address(0x64);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockArbSys arb;
    IPoolManager pm;
    V4Router router;
    OneShotDeployer deployer;
    PadToken tokenTemplate;
    PadGame gameTemplate;
    PvPPad pad;
    PadLiquidity liq;
    KingOfThePad king;
    PadGame pvp;
    PadToken pvpToken;

    address[] players;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        MockArbSys impl = new MockArbSys();
        vm.etch(ARB_ADDR, address(impl).code);
        arb = MockArbSys(ARB_ADDR);
        arb.set(1000);
        pm = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(OWNER)));
        router = new V4Router(pm);
        deployer = OneShotDeployer(deployCode("Base.t.sol:OneShotDeployer"));
        deployer.deployAll(OWNER, address(pm));
        tokenTemplate = deployer.token();
        gameTemplate = deployer.game();
        pad = deployer.pad();
        liq = deployer.liquidity();
        king = deployer.king();
        delete players;
        for (uint256 i; i < 12; ++i) {
            address p = address(uint160(0xA000 + i));
            players.push(p);
            vm.deal(p, 10 ether);
        }
    }

    // ---- helpers ---------------------------------------------------------------------------------
    function mineSalt() internal view returns (bytes32 salt) {
        bytes32 h = liq.hookInitCodeHash();
        address deployerAddr = address(liq);
        bytes memory buf = abi.encodePacked(bytes1(0xff), deployerAddr, bytes32(0), h);
        for (uint256 i; i < 200_000; ++i) {
            uint256 a;
            assembly ("memory-safe") {
                mstore(add(buf, 53), i)
                a := and(keccak256(add(buf, 32), 85), 0xffffffffffffffffffffffffffffffffffffffff)
            }
            if (a & 0x3FFF == 0x2000) {
                salt = bytes32(i);
                assertEq(liq.hookAddressFor(salt), address(uint160(a)));
                return salt;
            }
        }
        revert("no salt");
    }

    function openPad() internal {
        bytes32 salt = mineSalt();
        vm.prank(OWNER);
        pad.openPad(salt);
        pvp = PadGame(pad.gameOf(1));
        pvpToken = PadToken(pad.tokenOf(1));
    }

    function mintAll(PadGame g, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(players[i]);
            g.enter{value: 0.001 ether}();
        }
    }

    /// @dev Advance time and L2 blocks together (4 blocks per second, like Arbitrum).
    function advance(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        arb.advance(secs * 4);
        // Existing game tests advance over signup in one step. Drive the actual asynchronous draw
        // here, then index players by their randomized Imp order for the ranking assertions.
        for (uint256 id = 1; id <= pad.launchCount(); ++id) {
            PadGame g = PadGame(pad.gameOf(id));
            if (g.entryCount() != 0 && !g.drawComplete() && vm.getBlockTimestamp() >= g.signupEnd()) finishDraw(g);
        }
    }

    function finishDraw(PadGame g) internal {
        g.draw(32);
        arb.advance(4);
        while (!g.drawComplete()) g.draw(32);
        // Preserve the old suite's seat-based player labels, without influencing the raffle.
        if (address(g) == address(pvp) && g.impCount() <= players.length) {
            bool allKnown = true;
            for (uint256 i; i < g.impCount(); ++i) {
                address who = g.getImp(i).owner;
                bool known;
                for (uint256 j; j < players.length; ++j) {
                    if (players[j] == who) known = true;
                }
                if (!known) allKnown = false;
            }
            if (allKnown) {
                address[] memory ordered = new address[](players.length);
                for (uint256 i; i < g.impCount(); ++i) {
                    ordered[i] = g.getImp(i).owner;
                }
                uint256 at = g.impCount();
                for (uint256 j; j < players.length; ++j) {
                    if (g.impOf(players[j]) == 0) ordered[at++] = players[j];
                }
                for (uint256 j; j < players.length; ++j) {
                    players[j] = ordered[j];
                }
            }
        }
    }

    function donateFees(PoolKey memory key, uint256 e, uint256 t) internal {
        vm.deal(address(router), address(router).balance + e);
        if (t != 0) {
            // Move existing unlocked tokens from a roller, never inflate the total supply.
            address source = PadToken(key.currency1).balanceOf(players[0]) >= t ? players[0] : DEAD;
            vm.prank(source);
            PadToken(key.currency1).transfer(address(router), t);
        }
        router.donate(key, e, t);
    }

    function managerPrice(PoolKey memory key) internal view returns (uint160 price) {
        (price,,,) = StateLibrary.getSlot0(V4Manager(address(pm)), PoolId.wrap(keccak256(abi.encode(key))));
    }

    function rollAs(PadGame g, address who) internal {
        vm.prank(who);
        g.roll{value: 0.002 ether}();
    }

    /// @dev Signup, then every player rolls once per minute until the game ends by time, and finalizes.
    function playOut(PadGame g, uint256 n, uint256 rounds) internal {
        mintAll(g, n);
        advance(10 minutes);
        for (uint256 r; r < rounds; ++r) {
            for (uint256 i; i < n; ++i) {
                if (g.ended()) break;
                rollAs(g, players[i]);
            }
            advance(61);
        }
        while (!g.ended()) advance(60);
        advance(5);
        g.poke();
        if (!g.finalized()) g.finalize();
    }

    function gameClaims(PadGame g) internal view returns (uint256 total) {
        total = g.claimable(address(this));
        for (uint256 i; i < players.length; ++i) {
            total += g.claimable(players[i]);
        }
    }

    function gameReserves(PadGame g) internal view returns (uint256) {
        return gameClaims(g) + g.pendingCount() * g.ROLL_TIP() + g.drawBounty();
    }

    receive() external payable {}

    // Retained v3 regressions run on the explicitly required zero-IMD fallback path.
    // V4ConversionTest separately seeds a real IMD/ETH pool and exercises normal conversion.
    function graduateGame(PadGame g) internal {
        if (g.finalized() && !g.graduated() && g.ethRaised() != 0) {
            // The stall clock starts with the escrow, not at finalization.
            (,,,,, bool started,) = liq.conversions(address(g));
            if (!started) g.prepareConversion();
            (,,,, uint64 progress,,) = liq.conversions(address(g));
            uint256 deadline = uint256(progress) + 24 hours;
            if (vm.getBlockTimestamp() < deadline) vm.warp(deadline);
        }
        g.graduate();
    }

    function graduatePvp() internal {
        if (!pad.opened()) openPad();
        playOut(pvp, 4, 3);
        if (!pvp.graduated()) graduateGame(pvp);
        assertTrue(pad.genesisGraduated(), "pvp graduated");
    }
}
