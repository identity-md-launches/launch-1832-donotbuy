#!/usr/bin/env python3
"""Validate the committed static manifest and local artifacts, with no network or RPC."""
import json
from pathlib import Path
import re
import tomllib

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "launch.json").read_text())
assert set(manifest) == {"kind", "contracts", "notes"}
assert manifest["kind"] == "evm_contracts"
assert isinstance(manifest["notes"], str) and manifest["notes"]
imd = "0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127"
imd_eth_pool_id = "0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02"
expected = [
    ("PadToken", []),
    ("PadGame", []),
    ("PvPPad", ["$owner", "$contract:PadToken", "$contract:PadGame"]),
    ("PadLiquidity", ["0x8366a39cc670b4001a1121b8f6a443a643e40951", "$contract:PvPPad",
                      imd, imd_eth_pool_id]),
    ("KingOfThePad", ["$contract:PvPPad", "$contract:PadLiquidity", "$owner"]),
]


def flat_types(inputs):
    result = []
    for item in inputs:
        if item["type"] == "tuple":
            result += flat_types(item["components"])
        else:
            assert re.fullmatch(r"address|bool|bytes32|u?int(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)", item["type"])
            result.append(item["type"])
    return result


assert len(manifest["contracts"]) == len(expected) <= 8
seen = set()
total_runtime = 0
for item, (name, args) in zip(manifest["contracts"], expected):
    assert set(item) == {"contract", "constructorArgs"}
    assert item == {"contract": name, "constructorArgs": args}
    assert re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]{0,31}", name)
    assert name not in seen and len(args) <= 16
    artifact = json.loads((root / "out" / (name + ".sol") / (name + ".json")).read_text())
    constructors = [e for e in artifact["abi"] if e["type"] == "constructor"]
    assert len(constructors) == 1
    constructor = constructors[0]
    assert constructor["stateMutability"] == "nonpayable"
    types = flat_types(constructor["inputs"])
    assert len(args) == len(types)
    for arg, typ in zip(args, types):
        assert isinstance(arg, str)
        if arg.startswith("$contract:"):
            assert typ == "address" and arg.split(":", 1)[1] in seen
        elif arg == "$owner":
            assert typ == "address"
        elif typ == "address":
            assert re.fullmatch(r"0x[0-9a-f]{40}", arg) and int(arg, 16) != 0
        elif typ == "bytes32":
            assert re.fullmatch(r"0x[0-9a-f]{64}", arg)
        else:
            assert re.fullmatch(r"0|[1-9][0-9]*", arg)
            bits = int(re.search(r"[0-9]+", typ)[0])
            assert 0 <= int(arg) < 2 ** (bits - (1 if typ.startswith("int") else 0))
    seen.add(name)
    creation = bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))
    runtime = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    assert 0 < len(creation) + 32 * len(args) <= 49_152
    assert 0 < len(runtime) <= 24_576
    assert not artifact["bytecode"].get("linkReferences", {})
    assert not artifact["deployedBytecode"].get("linkReferences", {})
    pc = 0
    while pc < len(runtime):
        op = runtime[pc]
        assert op not in (0xF2, 0xF4, 0xFF), f"{name}: forbidden opcode {op:x} at {pc}"
        pc += 1 + (op - 0x5F if 0x60 <= op <= 0x7F else 0)
    total_runtime += len(runtime)
    print(f"{name}: init {len(creation):,}, runtime {len(runtime):,} bytes, {len(args)} static constructor words")
cfg = tomllib.loads((root / "foundry.toml").read_text())["profile"]["default"]
assert cfg["solc"] == "0.8.26"
assert cfg["bytecode_hash"] == "none" and cfg["cbor_metadata"] is False
assert cfg["ffi"] is False and cfg["fs_permissions"] == []
assert cfg["evm_version"] == "cancun"
assert cfg["optimizer"] is True and cfg["optimizer_runs"] == 1 and cfg["via_ir"] is True
assert cfg["libs"] == ["lib"]
print(f"Manifest valid; total application runtime {total_runtime:,} bytes, code-deposit gas {200 * total_runtime:,}.")
