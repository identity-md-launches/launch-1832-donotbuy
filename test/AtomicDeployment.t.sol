// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PvPPad} from "../src/PvPPad.sol";
import {PadLiquidity} from "../src/PadLiquidity.sol";
import {PoolKey} from "../src/interfaces/Interfaces.sol";
import {PadToken} from "../src/PadToken.sol";

/// @dev Raw CREATE2, matching the protected deployment probe. Passing artifact bytes avoids
/// Foundry's dynamic linking of Solidity `new`, which can undercount code-deposit gas in tests.
contract AtomicManifestProbe {
    uint256 public deploymentGas;

    function deploy(bytes[] memory codes, bytes32[] memory salts) external returns (address[] memory apps) {
        uint256 start = gasleft();
        apps = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            address app;
            assembly ("memory-safe") { app := create2(0, add(code, 32), mload(code), salt) }
            require(app != address(0), "deployment failed");
            apps[i] = app;
        }
        deploymentGas = start - gasleft();
    }
}

contract AtomicDeploymentTest is Test {
    address constant OWNER = 0x5b95A971B4583A5f011E9DA082acdD679b870D06;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function test_atomicManifestGasIncludingCalldataAndLaterGenesisFitsTarget() public {
        vm.warp(1_800_000_000);
        assertEq(MANAGER.code.length, 0, "no external dependency needed in constructors");
        assertEq(IMD.code.length, 0, "no external IMD call in constructors");
        AtomicManifestProbe probe = new AtomicManifestProbe();
        bytes[] memory codes = new bytes[](5);
        bytes32[] memory salts = new bytes32[](5);
        address[] memory predicted = new address[](5);
        string[5] memory artifacts = [
            "PadToken.sol:PadToken",
            "PadGame.sol:PadGame",
            "PvPPad.sol:PvPPad",
            "PadLiquidity.sol:PadLiquidity",
            "KingOfThePad.sol:KingOfThePad"
        ];
        for (uint256 i; i < 5; ++i) {
            bytes memory args;
            if (i == 2) args = abi.encode(OWNER, predicted[0], predicted[1]);
            if (i == 3) {
                args = abi.encode(
                    MANAGER, predicted[2], IMD, 0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02
                );
            }
            if (i == 4) args = abi.encode(predicted[2], predicted[3], OWNER);
            codes[i] = abi.encodePacked(vm.getCode(artifacts[i]), args);
            salts[i] = bytes32(i + 1);
            bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), address(probe), salts[i], keccak256(codes[i])));
            predicted[i] = address(uint160(uint256(digest)));
            assertLe(codes[i].length, 49_152);
        }
        bytes memory data = abi.encodeCall(AtomicManifestProbe.deploy, (codes, salts));
        uint256 intrinsic = 21_000;
        for (uint256 i; i < data.length; ++i) {
            intrinsic += data[i] == 0 ? 4 : 16;
        }
        uint256 start = gasleft();
        address[] memory deployed = probe.deploy{gas: 16_777_216}(codes, salts);
        // Measure inside the CREATE2 call. Foundry 1.8 may run the probe as a separate
        // top-level transaction; gasleft() in this test then omits the probe's code deposits.
        uint256 deploymentGas = probe.deploymentGas() + intrinsic + 23_000;
        emit log_named_uint("Raw CREATE2 manifest gas including calldata and intrinsic", deploymentGas);
        assertGt(
            deploymentGas,
            200
                * (deployed[0].code.length
                    + deployed[1].code.length
                    + deployed[2].code.length
                    + deployed[3].code.length
                    + deployed[4].code.length)
        );
        assertLt(deploymentGas, 16_777_216);
        for (uint256 i; i < 5; ++i) {
            assertEq(deployed[i], predicted[i]);
            assertGt(deployed[i].code.length, 0);
            assertLe(deployed[i].code.length, 24_576);
        }
        PvPPad pad = PvPPad(deployed[2]);
        PadLiquidity liquidity = PadLiquidity(payable(deployed[3]));
        assertEq(pad.launchCount(), 0);
        assertEq(PadToken(deployed[0]).totalSupply(), 0);
        assertEq(liquidity.poolCount(), 0);
        assertEq(
            keccak256(abi.encode(liquidity.imdEthKey())),
            0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02
        );
        assertEq(pad.owner(), OWNER);
        // Genesis is deliberately later, but also check the combined budget conservatively.
        bytes32 hash = liquidity.hookInitCodeHash();
        bytes32 hookSalt;
        bool found;
        for (uint256 i; i < 300_000; ++i) {
            address candidate = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(liquidity), bytes32(i), hash))))
            );
            if (uint160(candidate) & 0x3fff == 0x2000) {
                hookSalt = bytes32(i);
                found = true;
                break;
            }
        }
        assertTrue(found, "mined hook salt");
        start = gasleft();
        vm.prank(OWNER);
        pad.openPad(hookSalt);
        uint256 openingGas = start - gasleft() + 21_000 + 36 * 16;
        emit log_named_uint("Later openPad including hook and genesis gas", openingGas);
        emit log_named_uint("Combined manifest and later opening gas", deploymentGas + openingGas);
        assertLt(deploymentGas + openingGas, 13_000_000);
        assertEq(pad.launchCount(), 1);
        assertEq(PadToken(pad.tokenOf(1)).totalSupply(), 1_000_000_000 ether);
    }
}
