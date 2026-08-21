"""PUC credential and binary WebSocket protocol primitives."""

from __future__ import annotations

import base64
import struct
import uuid
from dataclasses import dataclass
from enum import IntEnum
from typing import Any

from Crypto.Cipher import DES
from Crypto.Util.Padding import pad

from .config import LoginConfig, PUC_REALM


MAGIC = 0xFF66
HEADER = struct.Struct(">HBBIHHHH")
DES_KEY = b"HytBSoft"


class MessageType(IntEnum):
    DEFAULT = 0
    HEARTBEAT = 1
    HEARTBEAT_ACK = 2
    AUTH = 3
    AUTH_ACK = 4


class FrameError(ValueError):
    """Raised when a PUC binary frame is malformed."""


@dataclass(frozen=True)
class PucFrame:
    message_type: MessageType
    body: bytes


def encrypt_password(password: str) -> str:
    cipher = DES.new(DES_KEY, DES.MODE_CBC, iv=DES_KEY)
    return cipher.encrypt(pad(password.encode("utf-8"), DES.block_size)).hex()


def build_authorization(account: str, password: str) -> str:
    credentials = f"{account}@{PUC_REALM}:{encrypt_password(password)}:0:0"
    encoded = base64.b64encode(credentials.encode("utf-8")).decode("ascii")
    return f"Basic {encoded}"


def crc16_java(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def encode_frame(body: bytes | str, message_type: MessageType) -> bytes:
    if isinstance(body, str):
        body = body.encode("utf-8")
    header = HEADER.pack(MAGIC, 0, 1, len(body), 0, int(message_type), crc16_java(body), 0)
    return header + body


def decode_frame(data: bytes) -> PucFrame:
    if len(data) < HEADER.size:
        raise FrameError("frame is shorter than its header")
    magic, _, version, length, _, raw_type, checksum, _ = HEADER.unpack(data[: HEADER.size])
    body = data[HEADER.size :]
    if magic != MAGIC or version != 1:
        raise FrameError("invalid frame header")
    if length != len(body):
        raise FrameError("invalid frame length")
    if checksum != crc16_java(body):
        raise FrameError("invalid frame checksum")
    try:
        message_type = MessageType(raw_type)
    except ValueError as exc:
        raise FrameError(f"unsupported message type: {raw_type}") from exc
    return PucFrame(message_type, body)


def build_login_payload(
    config: LoginConfig,
    token: str,
    *,
    guid: str | None = None,
) -> dict[str, Any]:
    return {
        "login_type": "web_our_company",
        "user_name": config.account,
        "password": config.password,
        "token": token,
        "OS": "Android",
        "product_name": "PUC",
        "version": "10",
        "cmd_name": "puc_login",
        "user_id": config.account,
        "realm": config.realm,
        "login_platform": 2,
        "cmd_guid": guid or str(uuid.uuid4()),
        "process_flag": 0,
        "imei_list": list(config.imei_list),
        "sn": config.sn,
    }
