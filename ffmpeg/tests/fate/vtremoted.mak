FATE_VTREMOTED += fate-vtremoted-roundtrip
fate-vtremoted-roundtrip: CMD = run $(SRC_PATH)/tests/vtremoted_test.sh
fate-vtremoted-roundtrip: CMP = oneline
fate-vtremoted-roundtrip: REF = OK

FATE_VTREMOTED += fate-vtremoted-decode
fate-vtremoted-decode: CMD = run $(SRC_PATH)/tests/vtremoted_decode_test.sh
fate-vtremoted-decode: CMP = oneline
fate-vtremoted-decode: REF = OK

FATE_VTREMOTED += fate-vtremoted-zstd
fate-vtremoted-zstd: CMD = run $(SRC_PATH)/tests/vtremoted_zstd_test.sh
fate-vtremoted-zstd: CMP = oneline
fate-vtremoted-zstd: REF = OK

FATE += $(FATE_VTREMOTED)
fate-vtremoted: $(FATE_VTREMOTED)
