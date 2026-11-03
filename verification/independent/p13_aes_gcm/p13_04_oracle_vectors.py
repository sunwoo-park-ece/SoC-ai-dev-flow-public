#!/usr/bin/env python3
"""Independent AESGCM reference. No DUT import, transcript or readback input.

Reference self-check: standard zero-key GCM empty and one-block examples.
Production packing: spec/14_aes_gcm.md 25.1, MSW-first words/MSB-first bytes.
Run with --check FILE to validate committed vectors; --emit DIR also creates
simulator text inputs in an already allocated, fresh local run directory.
"""
import argparse
import json
from pathlib import Path

import cryptography
from cryptography.hazmat.backends.openssl.backend import backend
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def selfcheck():
    aes = AESGCM(bytes(16))
    for plaintext, ciphertext, tag in [
        (b"", "", "58e2fccefa7e3061367f1d57a4e7455a"),
        (bytes(16), "0388dace60b6a392f328c2b971b2fe78",
         "ab6e47d42cec13bdf53a67b21257bddf"),
    ]:
        if len(ciphertext) != 2 * len(plaintext) or len(tag) != 32:
            raise ValueError("STANDARD_KAT_LITERAL_LENGTH")
        expected = ciphertext + tag
        actual = aes.encrypt(bytes(12), plaintext, b"")
        if actual.hex() != expected or aes.decrypt(bytes(12), actual, b"") != plaintext:
            raise ValueError("STANDARD_KAT_MISMATCH")


def derive():
    selfcheck()
    rows = []
    for pattern in range(2):
        key = bytes(range(16)) if pattern == 0 else bytes.fromhex("e1934bc72d8056af69103ef4b8520dca")
        for n in range(17):
            # Distinct IV for each encryption vector. Replaying E/D is DV only.
            iv = bytes.fromhex("10203000a1b2c3d4") + (n + 1).to_bytes(4, "big") if pattern == 0 else bytes.fromhex("c7510e9b28a4d36f") + (0x5a870100 + n).to_bytes(4, "big")
            p = bytes((0x10 + i if pattern == 0 else (i * 37 + 0x83) & 255) for i in range(n))
            aad = bytes.fromhex("a55a") + iv + n.to_bytes(2, "big")
            result = AESGCM(key).encrypt(iv, p, aad)
            if AESGCM(key).decrypt(iv, result, aad) != p:
                raise ValueError("ORACLE_ROUNDTRIP")
            rows.append(dict(id=len(rows), pattern=pattern, length=n, key=key.hex(), iv=iv.hex(),
                             aad=aad.hex(), plaintext=p.hex(), ciphertext=result[:-16].hex(), tag=result[-16:].hex()))
    return dict(schema=1, oracle="cryptography.AESGCM", cryptography=cryptography.__version__,
                backend=backend.openssl_version_text(), packing="MSW_FIRST_MSB_FIRST_LEFTMOST_LEN",
                standard_kat="ZERO_KEY_EMPTY_AND_ONE_BLOCK_PASS", vectors=rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", type=Path)
    ap.add_argument("--emit", type=Path)
    ap.add_argument("--write-vectors", type=Path)
    args = ap.parse_args()
    data = derive()
    if args.check and json.loads(args.check.read_text()) != data:
        raise ValueError("VECTOR_OR_PROVENANCE_MISMATCH")
    if args.write_vectors:
        with args.write_vectors.open("x") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
    if args.emit:
        with (args.emit / "oracle.json").open("x") as f:
            json.dump(data, f, indent=2)
        with (args.emit / "vectors.txt").open("x") as f:
            for v in data["vectors"]:
                f.write(f'{v["id"]} {v["length"]} {v["key"]} {v["iv"]} '
                        f'{v["plaintext"].ljust(32,"0")} {v["ciphertext"].ljust(32,"0")} {v["tag"]} {v["aad"]}\n')
    print(json.dumps({"oracle": data["oracle"], "version": data["cryptography"], "backend": data["backend"],
                      "standard_kat": data["standard_kat"], "vectors": len(data["vectors"])}))


if __name__ == "__main__":
    main()
