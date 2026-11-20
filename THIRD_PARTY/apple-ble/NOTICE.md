Swift proximity parser adapted from hudsonbrendon/apple-ble (MIT).
Source: https://github.com/hudsonbrendon/apple-ble
Commit: 1d74f4db41ee3b80fe074bbdd632128d880e13b5
Files: src/apple_ble/parser.py, tests/test_parser.py.
Changes: full product IDs, strict framing, CoreBluetooth adapter, event gate and notch integration.
No key extraction, encrypted payload handling, device tracking storage or pairing implementation included.

Also adapted in-ear flag decoding and public hardware-state fixtures from tests/test_crypto.py at the same pinned commit.
