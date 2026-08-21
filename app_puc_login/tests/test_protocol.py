import base64
import json
import struct

import pytest

from app_puc_login.config import LoginConfig
from app_puc_login.protocol import (
    FrameError,
    MessageType,
    build_authorization,
    build_login_payload,
    crc16_java,
    decode_frame,
    encrypt_password,
    encode_frame,
)


def test_encrypt_password_matches_java_des_vector():
    assert encrypt_password("123456") == "62c5928a69ac804d"


def test_authorization_matches_standard_sdk_shape():
    authorization = build_authorization("alice", "123456")
    decoded = base64.b64decode(authorization.removeprefix("Basic ")).decode()

    assert decoded == "alice@puc.com:62c5928a69ac804d:0:0"


def test_crc_matches_java_modbus_byte_swap():
    assert crc16_java(b"abc") == 0x5749


def test_frame_header_matches_java_layout():
    frame = encode_frame(b"abc", MessageType.AUTH)
    header = struct.unpack(">HBBIHHHH", frame[:16])

    assert header == (0xFF66, 0, 1, 3, 0, 3, 0x5749, 0)
    decoded = decode_frame(frame)
    assert decoded.message_type is MessageType.AUTH
    assert decoded.body == b"abc"


def test_decode_rejects_bad_checksum():
    frame = bytearray(encode_frame(b"abc", MessageType.AUTH))
    frame[-1] ^= 0xFF

    with pytest.raises(FrameError, match="checksum"):
        decode_frame(bytes(frame))


def test_login_payload_matches_standard_sdk_flow():
    config = LoginConfig(
        "alice",
        "secret",
        "https://puc.test",
        imei_list=("device-1",),
        sn="serial-1",
    )

    payload = build_login_payload(config, "token-1", guid="fixed-guid")

    assert payload == {
        "login_type": "web_our_company",
        "user_name": "alice",
        "password": "secret",
        "token": "token-1",
        "OS": "Android",
        "product_name": "PUC",
        "version": "10",
        "cmd_name": "puc_login",
        "user_id": "alice",
        "realm": "puc.com",
        "login_platform": 2,
        "cmd_guid": "fixed-guid",
        "process_flag": 0,
        "imei_list": ["device-1"],
        "sn": "serial-1",
    }
    json.dumps(payload)
