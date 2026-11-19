#!/usr/bin/env python3
# Copyright (c) 2026 Maja Błaszczak
# SPDX-License-Identifier: GPL-3.0-or-later
from __future__ import annotations

import argparse
import hashlib
import io
import json
import logging
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile
from pathlib import Path
from threading import RLock
from typing import Any

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger("freebuds")

JSON_MODE = False
_original_print = print


def print(*args, **kwargs):
    if JSON_MODE:
        import io

        buf = io.StringIO()
        kwargs_copy = dict(kwargs)
        kwargs_copy.pop("file", None)
        _original_print(*args, **kwargs_copy, file=buf)
        sys.stderr.write(buf.getvalue())
        sys.stderr.flush()
    else:
        _original_print(*args, **kwargs)


SPP_CHANNEL = 16

SIDE_LEFT = 1
SIDE_RIGHT = 2

CRC16_TABLE = [
    0, 4129, 8258, 12387, 16516, 20645, 24774, 28903,
    -32504, -28375, -24246, -20117, -15988, -11859, -7730, -3601,
    4657, 528, 12915, 8786, 21173, 17044, 29431, 25302,
    -27847, -31976, -19589, -23718, -11331, -15460, -3073, -7202,
    9314, 13379, 1056, 5121, 25830, 29895, 17572, 21637,
    -23190, -19125, -31448, -27383, -6674, -2609, -14932, -10867,
    13907, 9842, 5649, 1584, 30423, 26358, 22165, 18100,
    -18597, -22662, -26855, -30920, -2081, -6146, -10339, -14404,
    18628, 22757, 26758, 30887, 2112, 6241, 10242, 14371,
    -13876, -9747, -5746, -1617, -30392, -26263, -22262, -18133,
    23285, 19156, 31415, 27286, 6769, 2640, 14899, 10770,
    -9219, -13348, -1089, -5218, -25735, -29864, -17605, -21734,
    27814, 31879, 19684, 23749, 11298, 15363, 3168, 7233,
    -4690, -625, -12820, -8755, -21206, -17141, -29336, -25271,
    32407, 28342, 24277, 20212, 15891, 11826, 7761, 3696,
    -97, -4162, -8227, -12292, -16613, -20678, -24743, -28808,
    -28280, -32343, -20022, -24085, -12020, -16083, -3762, -7825,
    4224, 161, 12482, 8419, 20484, 16421, 28742, 24679,
    -31815, -27752, -23557, -19494, -15555, -11492, -7297, -3234,
    689, 4752, 8947, 13010, 16949, 21012, 25207, 29270,
    -18966, -23093, -27224, -31351, -2706, -6833, -10964, -15091,
    13538, 9411, 5280, 1153, 29798, 25671, 21540, 17413,
    -22565, -18438, -30823, -26696, -6305, -2178, -14563, -10436,
    9939, 14066, 1681, 5808, 26199, 30326, 17941, 22068,
    -9908, -13971, -1778, -5841, -26168, -30231, -18038, -22101,
    22596, 18533, 30726, 26663, 6336, 2273, 14466, 10403,
    -13443, -9380, -5313, -1250, -29703, -25640, -21573, -17510,
    19061, 23124, 27191, 31254, 2801, 6864, 10931, 14994,
    -722, -4849, -8852, -12979, -16982, -21109, -25112, -29239,
    31782, 27655, 23652, 19525, 15522, 11395, 7392, 3265,
    -4321, -194, -12451, -8324, -20581, -16454, -28711, -24584,
    28183, 32310, 20053, 24180, 11923, 16050, 3793, 7920,
]


def crc16(data: bytes) -> int:
    crc = 0
    for b in data:
        idx = ((crc >> 8) ^ b) & 0xFF
        crc = (CRC16_TABLE[idx] ^ (crc << 8)) & 0xFFFF
    return crc


class Cmd:
    BATTERY = bytes([0x01, 0x08, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00])
    VERSION = bytes(
        [0x01, 0x07]
        + [x for i in (*range(1, 13), 15, 24, 25) for x in (i, 0x00)]
    )
    CMD_01_1D = bytes([0x01, 0x1D, 0x01, 0x01, 0x01])

    GET_SERVICE_ABILITY = bytes([0x01, 0x02, 0x01, 0x00])
    GET_COMMAND_ABILITY = bytes([0x01, 0x03, 0x01, 0x00])

    @staticmethod
    def set_double_click(side: int, action: int) -> bytes:
        return bytes([0x01, 0x1F, side, 0x01, action])

    GET_DOUBLE_CLICK = bytes([0x01, 0x20, 0x03, 0x00])
    CLOUD_VERSION = bytes([0x09, 0x08])
    GET_OTA_PARAMS = bytes([0x09, 0x02, 0x01, 0x00])
    CANCEL_OTA = bytes([0x09, 0x08])
    CHECK_OTA_STATE = bytes([0x09, 0x01, 0x01, 0x00])
    LANGUAGE_PSI = bytes([0x0A, 0x0E, 0x02, 0x01, 0x00])
    GET_LANGUAGE = bytes([0x0C, 0x02, 0x01, 0x00, 0x03, 0x00])
    GET_LANGUAGE_WITH_UNIT = bytes([0x0C, 0x02, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00])
    GET_PROMPT_LANGUAGE_PACK = bytes([0x2B, 0x51])

    @staticmethod
    def set_language(lang_str: str) -> bytes:
        lang_bytes = lang_str.encode("us-ascii", errors="ignore")
        return bytes([0x0C, 0x01, 0x01, len(lang_bytes)]) + lang_bytes

    GET_GREET = bytes([0x2B, 0x0F, 0x01, 0x00])

    @staticmethod
    def set_greet(enable: bool) -> bytes:
        return bytes([0x2B, 0x0E, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_WEAR = bytes([0x2B, 0x11, 0x01, 0x00])

    @staticmethod
    def set_wear(enable: bool) -> bytes:
        return bytes([0x2B, 0x10, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_LONG_PRESS = bytes([0x2B, 0x17, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00])

    @staticmethod
    def set_long_press(side: int, action: int) -> bytes:
        return bytes([0x2B, 0x16, side, 0x01, action])

    GET_SHORT_PRESS = bytes([0x2B, 0x21, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00])

    @staticmethod
    def set_short_press(side: int, action: int) -> bytes:
        return bytes([0x2B, 0x20, side, 0x01, action])

    GET_SLIDE = bytes([0x2B, 0x1F, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00])

    @staticmethod
    def set_slide(side: int, action: int) -> bytes:
        return bytes([0x2B, 0x1E, side, 0x01, action])

    GET_SAVING_MODE = bytes([0x2B, 0x1D, 0x01, 0x00])

    @staticmethod
    def set_saving_mode(enable: bool) -> bytes:
        return bytes([0x2B, 0x1C, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_INTELLECT_VOLUME = bytes([0x2B, 0x23, 0x01, 0x00])

    @staticmethod
    def set_intellect_volume(enable: bool) -> bytes:
        return bytes([0x2B, 0x22, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_ANC_STATE = bytes([0x2B, 0x05, 0x01, 0x00])
    GET_ANC_MODE_LEVEL = bytes([0x2B, 0x07, 0x01, 0x00])
    QUERY_NOISE_REDUCTION_MODE = bytes([0x2B, 0x2A, 0x01, 0x00])
    GET_NOISE_CONTROL = bytes([0x2B, 0x19, 0x01, 0x00, 0x02, 0x00])

    @staticmethod
    def set_anc_state(mode: int) -> bytes:
        return bytes([0x2B, 0x04, 0x01, 0x01, mode & 0xFF])

    @staticmethod
    def set_anc_state_level(mode: int, level: int = 0xFF) -> bytes:
        return bytes([0x2B, 0x04, 0x01, 0x02, mode & 0xFF, level & 0xFF])

    @staticmethod
    def set_anc_level(level: int) -> bytes:
        return bytes([0x2B, 0x08, 0x01, 0x01, level & 0xFF])

    @staticmethod
    def set_noise_control(
        left: int | None, right: int | None = None
    ) -> bytes:
        payload = bytearray((0x2B, 0x18))
        for tag, value in ((1, left), (2, right)):
            if value is not None:
                payload.extend((tag, 1, value))
        return bytes(payload)

    GET_EQ = bytes([0x2B, 0x4A, 0x02, 0x00])

    @staticmethod
    def set_eq(mode: int) -> bytes:
        return bytes([0x2B, 0x49, 0x01, 0x01, mode & 0xFF])

    GET_EQ_EXTENDED_SUPPORT = bytes([0x2B, 0xA8, 0x01, 0x01])

    GET_TRIPLE_CLICK = bytes([0x01, 0x26, 0x01, 0x00, 0x02, 0x00])

    @staticmethod
    def set_triple_click(left: int, right: int) -> bytes:
        payload = bytearray([0x01, 0x25])
        if left is not None:
            payload += bytes([0x01, 0x01, left & 0xFF])
        if right is not None:
            payload += bytes([0x02, 0x01, right & 0xFF])
        return bytes(payload)

    GET_DOUBLE_CLICK_MBB = bytes([0x01, 0x20, 0x01, 0x00, 0x02, 0x00])
    GET_DOUBLE_CLICK_CALL = bytes([0x01, 0x20, 0x04, 0x00])

    @staticmethod
    def set_double_click_mbb(left: int, right: int) -> bytes:
        payload = bytearray([0x01, 0x1F])
        if left is not None:
            payload += bytes([0x01, 0x01, left & 0xFF])
        if right is not None:
            payload += bytes([0x02, 0x01, right & 0xFF])
        return bytes(payload)

    @staticmethod
    def set_double_click_call(action: int) -> bytes:
        return bytes([0x01, 0x1F, 0x04, 0x01, action & 0xFF])

    GET_LONG_PRESS_MBB = bytes([0x2B, 0x17, 0x01, 0x00, 0x02, 0x00])
    GET_LONG_PRESS_CALL = bytes([0x2B, 0x17, 0x04, 0x00, 0x05, 0x00])

    @staticmethod
    def set_long_press_mbb(left: int, right: int) -> bytes:
        payload = bytearray([0x2B, 0x16])
        if left is not None:
            payload += bytes([0x01, 0x01, left & 0xFF])
        if right is not None:
            payload += bytes([0x02, 0x01, right & 0xFF])
        return bytes(payload)

    @staticmethod
    def set_long_press_call(action: int) -> bytes:
        return bytes([0x2B, 0x16, 0x04, 0x01, action & 0xFF])

    GET_SLIDE_MBB = bytes([0x2B, 0x1F, 0x01, 0x00, 0x02, 0x00])

    @staticmethod
    def set_slide_mbb(left: int, right: int) -> bytes:
        payload = bytearray([0x2B, 0x1E])
        if left is not None:
            payload += bytes([0x01, 0x01, left & 0xFF])
        if right is not None:
            payload += bytes([0x02, 0x01, right & 0xFF])
        return bytes(payload)

    GET_PINCH = bytes([0x2B, 0x21, 0x01, 0x00, 0x02, 0x00])

    @staticmethod
    def set_pinch(left: int, right: int) -> bytes:
        payload = bytearray([0x2B, 0x20])
        if left is not None:
            payload += bytes([0x01, 0x01, left & 0xFF])
        if right is not None:
            payload += bytes([0x02, 0x01, right & 0xFF])
        return bytes(payload)

    GET_LIGHT_HOLD = bytes([0x2B, 0x93, 0x01, 0x00, 0x02, 0x00])

    @staticmethod
    def set_light_hold(left: int, right: int) -> bytes:
        payload = bytearray([0x2B, 0x92])
        if left is not None:
            payload += bytes([0x01, 0x01, left & 0xFF])
        if right is not None:
            payload += bytes([0x02, 0x01, right & 0xFF])
        return bytes(payload)

    GET_GAME_LOW_LATENCY = bytes([0x2B, 0x6C, 0x02, 0x00])

    @staticmethod
    def set_game_low_latency(enable: bool) -> bytes:
        return bytes([0x2B, 0x6C, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_DUAL_CONNECT = bytes([0x2B, 0x2F, 0x01, 0x00])

    @staticmethod
    def set_dual_connect(enable: bool) -> bytes:
        return bytes([0x2B, 0x2E, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_TRANSLATE_MODE = bytes([0x2B, 0x4D, 0x01, 0x00])

    @staticmethod
    def set_translate_mode(enable: bool) -> bytes:
        return bytes([0x2B, 0x4C, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_VOICE_ENHANCE = bytes([0x2B, 0x42, 0x01, 0x01])

    @staticmethod
    def set_voice_enhance(enable: bool) -> bytes:
        return bytes([0x2B, 0x41, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_32K_HD = bytes([0x2B, 0x46, 0x01, 0x01])

    @staticmethod
    def set_32k_hd(enable: bool) -> bytes:
        return bytes([0x2B, 0x45, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_HD_SWITCH = bytes([0x2B, 0xA3, 0x01, 0x01])

    @staticmethod
    def set_hd_switch(enable: bool) -> bytes:
        v = 0x01 if enable else 0x00
        return bytes([0x2B, 0xA2, 0x01, 0x01, v])

    GET_LEFT_RIGHT_EAR = bytes([0x2B, 0x9A, 0x01, 0x00])

    @staticmethod
    def set_left_right_ear(enable: bool) -> bytes:
        return bytes([0x2B, 0x99, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_WIND_MODE = bytes([0x2B, 0x95, 0x01, 0x01])

    @staticmethod
    def set_wind_mode(enable: bool) -> bytes:
        return bytes([0x2B, 0x94, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_WEARING_STATUS = bytes([0x2B, 0x25, 0x01, 0x00, 0x02, 0x00])
    GET_DORMANT_TIME = bytes([0x2B, 0x48, 0x01, 0x00])

    @staticmethod
    def set_dormant_time(option: int, seconds: int) -> bytes:
        ts = seconds.to_bytes(4, "big")
        return bytes([0x2B, 0x47, 0x01, 0x01, option & 0xFF, 0x01, 0x04]) + ts

    GET_SILENT_UPGRADE = bytes([0x2B, 0x70, 0x01, 0x01])

    @staticmethod
    def set_silent_upgrade(enable: bool) -> bytes:
        return bytes([0x2B, 0x6F, 0x01, 0x01, 0x01 if enable else 0x00])

    GET_BT_MAIN_STATUS = bytes([0x2B, 0x6A, 0x01, 0x01])
    GET_CLOSE_COVER_REMIND = bytes([0x2B, 0x7F, 0x01, 0x01])
    GET_MUSIC_MODE = bytes([0x2B, 0x53, 0x02, 0x00])
    GET_HEALTH_ALERTS = bytes([0x2B, 0x61, 0x01, 0x00])

    @staticmethod
    def set_health_alerts(enable: bool) -> bytes:
        return bytes([0x2B, 0x60, 0x01, 0x01, 0x01 if enable else 0x00])

    FACTORY_RESET = bytes([0x01, 0x0D, 0x01, 0x01, 0x01])
    GET_AMBIENT_SOUND = bytes([0x2B, 0x2C, 0x01, 0x00])
    GET_CONNECT_ABILITY = bytes([0x2B, 0x2D, 0x01, 0x00])
    QUERY_PAIR = bytes([0x2B, 0x8F, 0x01, 0x00])
    STATE_PAIR = bytes([0x2B, 0x90, 0x01, 0x01, 0x01])
    GET_DEVICES_BONDED = bytes([0x2B, 0x31, 0x01, 0x00])

    @staticmethod
    def get_bonded_by_index(index: int) -> bytes:
        return bytes([0x2B, 0x31, 0x03, 0x01, index & 0xFF])

    @staticmethod
    def get_bonded_by_mac(mac: bytes) -> bytes:
        return bytes([0x2B, 0x31, 0x04, 0x06]) + mac

    @staticmethod
    def set_primary_device(mac: bytes) -> bytes:
        return bytes([0x2B, 0x32, 0x01, 0x06]) + mac

    @staticmethod
    def single_device_setting(sub: int, mac: bytes) -> bytes:
        return bytes([0x2B, 0x33, sub & 0xFF, 0x06]) + mac

    GET_FIT_CHECK = bytes([0x2B, 0x26, 0x01, 0x00])
    EXIT_FIT_CHECK = bytes([0x2B, 0x26, 0x03, 0x00])
    GET_FIT_DETECT_VERSION = bytes([0x2B, 0x37, 0x01, 0x00])
    HEARTBEAT = bytes([0x2B, 0x4E, 0x01, 0x00])

    SET_TIME = None


GESTURE_ACTIONS = {
    0: "None/Default",
    1: "Voice assistant",
    2: "Noise control",
    3: "Previous track",
    4: "Next track",
    5: "Volume up",
    6: "Volume down",
    7: "Play/Pause",
    8: "Answer call",
}

DC_ACTIONS = {
    0: "Voice assistant",
    1: "Play/Pause",
    2: "Next track",
    7: "Previous track",
    255: "None",
}

LP_ACTIONS = {
    10: "Noise control",
    14: "Song recognition",
    15: "Freestyle listen",
    255: "None",
}

TRIPLE_ACTIONS = {2: "Next track", 7: "Previous track", 255: "None"}
SLIDE_ACTIONS = {0: "Volume", 255: "None"}
CALL_ACTIONS = {
    "long_press": {0: "Reject call", 255: "None"},
    "double_click": {0: "Answer/End call", 255: "None"},
}

PINCH_ACTIONS = {
    0: "Face-to-face translate",
    1: "Voice memo",
    2: "Pairing",
    3: "Freestyle listen",
    4: "Pinch chat",
    5: "Song recognition",
    255: "None",
}

ACTION_NOISE_CONTROL = {
    "long_press": 10,
}

NOISE_CYCLES = {
    1: "Noise cancelling / Off",
    2: "Noise cancelling / Off / Awareness",
    3: "Noise cancelling / Awareness",
    4: "Off / Awareness",
}

CALL_SETTERS = {
    "double_click": Cmd.set_double_click_call,
    "long_press": Cmd.set_long_press_call,
}

ACTION_RESULT = {
    0: "Left OK",
    1: "Left failed",
    2: "Right OK",
    3: "Right failed",
}

NC_MODE_OFF = 0
NC_MODE_ON = 1
NC_MODE_AWARE = 2

NC_MODES = {
    NC_MODE_OFF: "Off",
    NC_MODE_ON: "On",
    NC_MODE_AWARE: "Awareness",
}
NC_MODE_ALIASES = {
    "off": NC_MODE_OFF,
    "0": NC_MODE_OFF,
    "cancel": NC_MODE_OFF,
    "on": NC_MODE_ON,
    "noise": NC_MODE_ON,
    "1": NC_MODE_ON,
    "aware": NC_MODE_AWARE,
    "awareness": NC_MODE_AWARE,
    "transparent": NC_MODE_AWARE,
    "pass": NC_MODE_AWARE,
    "pass_through": NC_MODE_AWARE,
    "2": NC_MODE_AWARE,
}

NC_LEVEL_GENERAL = 0
NC_LEVEL_COZY = 1
NC_LEVEL_ULTRA = 2
NC_LEVEL_DYNAMIC = 3

NC_LEVELS = {
    NC_LEVEL_GENERAL: "General",
    NC_LEVEL_COZY: "Cozy",
    NC_LEVEL_ULTRA: "Ultra",
    NC_LEVEL_DYNAMIC: "Dynamic",
}
NC_LEVEL_ALIASES = {
    "general": NC_LEVEL_GENERAL,
    "balance": NC_LEVEL_GENERAL,
    "0": NC_LEVEL_GENERAL,
    "cozy": NC_LEVEL_COZY,
    "comfortable": NC_LEVEL_COZY,
    "light": NC_LEVEL_COZY,
    "1": NC_LEVEL_COZY,
    "ultra": NC_LEVEL_ULTRA,
    "deep": NC_LEVEL_ULTRA,
    "deeply": NC_LEVEL_ULTRA,
    "depth": NC_LEVEL_ULTRA,
    "2": NC_LEVEL_ULTRA,
    "dynamic": NC_LEVEL_DYNAMIC,
    "ai": NC_LEVEL_DYNAMIC,
    "smart": NC_LEVEL_DYNAMIC,
    "3": NC_LEVEL_DYNAMIC,
}


def resolve_anc_level(value) -> int | None:
    if isinstance(value, int):
        return value if value in NC_LEVELS else None
    if isinstance(value, str):
        return NC_LEVEL_ALIASES.get(value.strip().lower())
    return None


EQ_MODE_DEFAULT = 1
EQ_MODE_BASS = 2
EQ_MODE_TREBLE = 3
EQ_MODE_VOICES = 9

EQ_MODES = {
    EQ_MODE_DEFAULT: "Default",
    EQ_MODE_BASS: "Bass boost",
    EQ_MODE_TREBLE: "Treble boost",
    EQ_MODE_VOICES: "Voices",
}
EQ_MODE_ALIASES = {
    "default": EQ_MODE_DEFAULT,
    "balanced": EQ_MODE_DEFAULT,
    "1": EQ_MODE_DEFAULT,
    "bass": EQ_MODE_BASS,
    "bassboost": EQ_MODE_BASS,
    "2": EQ_MODE_BASS,
    "treble": EQ_MODE_TREBLE,
    "trebleboost": EQ_MODE_TREBLE,
    "3": EQ_MODE_TREBLE,
    "voices": EQ_MODE_VOICES,
    "voice": EQ_MODE_VOICES,
    "clearvoice": EQ_MODE_VOICES,
    "9": EQ_MODE_VOICES,
}


def resolve_eq_mode(value) -> int | None:
    if isinstance(value, int):
        return value if value in EQ_MODES else None
    if isinstance(value, str):
        return EQ_MODE_ALIASES.get(value.strip().lower())
    return None


_CMD_NAMES = {
    "help",
    "bat",
    "ver",
    "info",
    "find",
    "fit",
    "gesture",
    "cycle",
    "anc",
    "nc",
    "sfx",
    "lang",
    "raw",
    "misc",
    "devices",
    "dev",
}

GESTURE_TYPES: dict[str, Any] = {
    "long_press": {
        "name": "Long press",
        "aliases": ("lp", "long"),
        "get": Cmd.GET_LONG_PRESS_MBB,
        "set": Cmd.set_long_press_mbb,
        "svc": 0x2B,
        "cmd": 0x17,
        "set_cmd": 0x16,
        "actions": LP_ACTIONS,
    },
    "slide": {
        "name": "Slide",
        "aliases": ("slide", "sl"),
        "get": Cmd.GET_SLIDE_MBB,
        "set": Cmd.set_slide_mbb,
        "svc": 0x2B,
        "cmd": 0x1F,
        "set_cmd": 0x1E,
        "actions": SLIDE_ACTIONS,
    },
    "double_click": {
        "name": "Double click",
        "aliases": ("dc", "double"),
        "get": Cmd.GET_DOUBLE_CLICK_MBB,
        "set": Cmd.set_double_click_mbb,
        "svc": 0x01,
        "cmd": 0x20,
        "set_cmd": 0x1F,
        "actions": DC_ACTIONS,
    },
    "triple_click": {
        "name": "Triple click",
        "aliases": ("triple", "tri", "tc"),
        "get": Cmd.GET_TRIPLE_CLICK,
        "set": Cmd.set_triple_click,
        "svc": 0x01,
        "cmd": 0x26,
        "set_cmd": 0x25,
        "actions": TRIPLE_ACTIONS,
    },
}

GESTURE_ALIASES = {}
for _gkey, _gtype in GESTURE_TYPES.items():
    GESTURE_ALIASES[_gkey] = _gkey
    for _alias in _gtype["aliases"]:
        GESTURE_ALIASES[_alias] = _gkey

_CMD_NAMES.update(GESTURE_ALIASES)

FEATURES: dict[str, Any] = {
    "wear": {
        "name": "Wear detection",
        "get": "get_wear_setting",
        "set": "set_wear",
    },
    "glat": {
        "name": "Game low latency",
        "get": "get_game_low_latency",
        "set": "set_game_low_latency",
    },
    "dual": {
        "name": "Dual connect",
        "get": "get_dual_connect",
        "set": "set_dual_connect",
    },
    "venh": {
        "name": "Voice enhance",
        "get": "get_voice_enhance",
        "set": "set_voice_enhance",
    },
    "hd": {
        "name": "Prioritize sound quality",
        "get": "get_hd_switch",
        "set": "set_hd_switch",
    },
    "wind": {
        "name": "Wind mode",
        "get": "get_wind_mode",
        "set": "set_wind_mode",
    },
    "silent": {
        "name": "Silent upgrade",
        "get": "get_silent_upgrade",
        "set": "set_silent_upgrade",
    },
    "health": {
        "name": "Health alerts",
        "get": "get_health_alerts",
        "set": "set_health_alerts",
    },
    "dynamic": {
        "name": "Dynamic ANC capability",
        "get": "get_dynamic_anc_support",
    },
    "wearst": {"name": "Wearing status", "get": "get_wearing_status"},
    "btmain": {"name": "BT main status", "get": "get_bt_main_status"},
    "music": {"name": "Music mode", "get": "get_music_mode"},
    "ambient": {"name": "Ambient sound", "get": "get_ambient_sound"},
    "conn": {"name": "Connect ability", "get": "get_connect_ability"},
}


def print_status(label: str, status: int) -> None:
    if status == 100003:
        print(f"{label}: Not supported by device")
    else:
        print(f"{label}: status=0x{status:08X}")


def build_frame(cmd_payload: bytes) -> bytes:
    total_len = len(cmd_payload)
    frame_len = total_len + 1
    frame = bytearray(4 + total_len + 2)
    frame[0] = 0x5A
    frame[1] = (frame_len >> 8) & 0xFF
    frame[2] = frame_len & 0xFF
    frame[3] = 0x00
    frame[4:4 + total_len] = cmd_payload
    crc_val = crc16(bytes(frame[: 4 + total_len]))
    frame[4 + total_len] = (crc_val >> 8) & 0xFF
    frame[4 + total_len + 1] = crc_val & 0xFF
    return bytes(frame)


def parse_frames(data: bytes) -> list[dict]:
    frames = []
    offset = 0
    while offset < len(data):
        if data[offset] != 0x5A:
            offset += 1
            continue
        remaining = data[offset:]
        if len(remaining) < 4:
            break
        frame_len = (remaining[1] << 8) | remaining[2]
        total = 4 + (frame_len - 1) + 2
        if len(remaining) < total:
            break
        frame_data = remaining[:total]
        payload = frame_data[4:4 + (frame_len - 1)]
        crc_recv = (frame_data[-2] << 8) | frame_data[-1]
        crc_calc = crc16(frame_data[:-2])
        frames.append(
            {
                "payload": payload,
                "svc": payload[0] if len(payload) > 0 else 0,
                "cmd": payload[1] if len(payload) > 1 else 0,
                "data": payload[2:] if len(payload) > 2 else b"",
                "crc_ok": crc_recv == crc_calc,
            }
        )
        offset += total
    return frames


def parse_tlv(data: bytes) -> list[dict]:
    entries = []
    pos = 0
    while pos < len(data) - 1:
        tag = data[pos]
        length = data[pos + 1]
        if pos + 2 + length > len(data):
            break
        value = data[pos + 2:pos + 2 + length]
        entries.append({"tag": tag, "len": length, "value": value})
        pos += 2 + length
    return entries


def mac_to_bytes(mac: str) -> bytes:
    return bytes.fromhex(mac.replace(":", "").replace("-", ""))


def mac_to_str(raw: bytes) -> str:
    if len(raw) != 6:
        return raw.hex()
    return ":".join(f"{b:02X}" for b in raw)


FIT_RESOURCE_URL = (
    "https://contentcenter-dre.dbankcdn.cn/pub_1/HW-SmartHome_oem_900_9/"
    "b0/v3/eu/device/guide/000145/000145_01.zip"
)
FIT_AUDIO_HASH = (
    "dcdb02ba6eb810f19cb6a298fd53c3fa7e22a47076aea86a062ce3c8bbbf9ed3"
)


def fit_audio() -> Path:
    destination = (
        Path.home() / ".cache" / "freebuds-controller" / "detect_music.ogg"
    )
    if (
        destination.is_file()
        and hashlib.sha256(destination.read_bytes()).hexdigest()
        == FIT_AUDIO_HASH
    ):
        return destination
    with urllib.request.urlopen(FIT_RESOURCE_URL, timeout=30) as response:
        with zipfile.ZipFile(io.BytesIO(response.read())) as archive:
            audio = archive.read("000145_01/detect_music.ogg")
    if hashlib.sha256(audio).hexdigest() != FIT_AUDIO_HASH:
        raise ValueError("Unexpected Huawei fit-test audio checksum")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=destination.parent, delete=False
    ) as stream:
        stream.write(audio)
    Path(stream.name).replace(destination)
    return destination


class FreeBudsController:
    def __init__(self, mac_address: str | None = None):
        self.mac_address = mac_address
        self.sock: socket.socket | None = None
        self._connected = False
        self._lock = RLock()

    def connect(
        self, mac_address: str | None = None, channel: int = SPP_CHANNEL
    ) -> bool:
        if mac_address:
            self.mac_address = mac_address
        if not self.mac_address:
            log.error("No MAC address")
            return False

        mac = self.mac_address.upper().replace("-", ":")
        if not re.match(r"^([0-9A-F]{2}:){5}[0-9A-F]{2}$", mac):
            raise ValueError(f"Invalid MAC: {mac_address}")

        log.debug(f"Connecting SPP to {mac} (channel {channel})...")
        try:
            self.sock = socket.socket(
                socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM
            )
            self.sock.settimeout(10)
            self.sock.connect((mac, channel))
            self._connected = True
            log.debug("Connected")
            return True
        except Exception as e:
            log.error(f"Connect failed: {e}")
            self._connected = False
            return False

    def disconnect(self):
        with self._lock:
            if self.sock:
                try:
                    self.sock.close()
                except OSError:
                    pass
                self.sock = None
            self._connected = False
        log.debug("Disconnected")

    def send_command(
        self, cmd_payload: bytes, read_timeout: float = 2.0
    ) -> list[dict]:
        if not self._connected or not self.sock:
            log.error("Not connected")
            return []

        with self._lock:
            try:
                frame = build_frame(cmd_payload)
                log.debug(f">> {frame.hex()}")
                self.sock.sendall(frame)

                response = b""
                self.sock.settimeout(read_timeout)
                while True:
                    try:
                        chunk = self.sock.recv(4096)
                        if not chunk:
                            self.disconnect()
                            break
                        response += chunk
                        log.debug(f"<< {chunk.hex()}")
                    except TimeoutError:
                        break

                return [f for f in parse_frames(response) if f["crc_ok"]]

            except Exception as e:
                log.error(f"Send error: {e}")
                self.disconnect()
                return []

    def _match_frame(
        self, frames: list[dict], svc: int, cmd: int
    ) -> dict | None:
        for f in frames:
            if f["svc"] == svc and f["cmd"] == cmd:
                return f
        return None

    def _extract_byte_at(self, data: bytes, offset: int) -> int | None:
        if offset < len(data):
            return data[offset]
        return None

    def _extract_tlv_value(
        self, data: bytes, target_tag: int
    ) -> bytes | None:
        for tlv in parse_tlv(data):
            if tlv["tag"] == target_tag:
                return tlv["value"]
        return None

    def _is_status_response(self, data: bytes) -> bool:
        return len(data) >= 6 and data[0] == 0x7F and data[1] == 0x04

    def _parse_status_code(self, data: bytes) -> int | None:
        if self._is_status_response(data) and len(data) >= 6:
            return (data[2] << 24) | (data[3] << 16) | (data[4] << 8) | data[5]
        return None

    def get_battery(self) -> dict | None:
        frames = self.send_command(Cmd.BATTERY)
        f = self._match_frame(frames, 0x01, 0x08)
        if not f:
            log.warning("No battery frame found")
            return None

        val = self._extract_tlv_value(f["data"], 2)
        if val and len(val) >= 3:
            bat = {
                "left_battery": val[0],
                "right_battery": val[1],
                "box_battery": val[2],
            }
            charging = self._extract_tlv_value(f["data"], 3) or b""
            for side, state in zip(("left", "right", "box"), charging):
                bat[side + "_charging"] = bool(state)
            in_box = self._extract_tlv_value(f["data"], 5) or b""
            for side, state in zip(("left", "right"), in_box):
                if state in (0, 1):
                    bat[side + "_in_box"] = bool(state)
            log.debug(
                f"Battery: L={bat['left_battery']}% "
                f"R={bat['right_battery']}% Box={bat['box_battery']}%"
            )
            return bat
        log.warning("Battery: no tag=2 found in TLV")
        return None

    def get_version(self) -> dict | None:
        frames = self.send_command(Cmd.VERSION)
        f = self._match_frame(frames, 0x01, 0x07)
        if not f:
            log.warning("No version frame found")
            return None

        known = {
            1: "bluetooth_version",
            3: "model",
            7: "firmware",
            9: "serial",
            10: "bt_version",
            15: "bt_prefix",
            24: "bud_serials",
        }
        result = {}
        for tlv in parse_tlv(f["data"]):
            tag = tlv["tag"]
            if tag == 25 and tlv["value"]:
                result["sub_model_id"] = f"{tlv['value'][0]:02X}"
                continue
            try:
                val = (
                    tlv["value"]
                    .decode("utf-8", errors="ignore")
                    .strip()
                    .rstrip("\x00")
                )
                if val and len(val) < 100:
                    key = known.get(tag, f"field_{tag}")
                    result[key] = val
                    if tag == 15:
                        result["ota_package"] = val
                    if key == "firmware":
                        log.debug(f"Firmware: {val}")
            except Exception:
                pass

        if result:
            return result
        log.warning("Version: no parseable data")
        return None

    def _parse_bool_get(
        self,
        frames: list[dict],
        svc: int,
        cmd_get: int,
        cmd_set: int,
        name: str,
    ) -> dict | None:

        f = self._match_frame(frames, svc, cmd_get)
        if not f:
            f = self._match_frame(frames, svc, cmd_set)
        if not f:
            log.warning(f"No {name} response")
            return None

        data = f["data"]

        status = self._parse_status_code(data)
        if status is not None:
            result = {
                "status": status,
                "status_ok": status == 100000,
                "raw": data.hex(),
            }
            if status == 100000:
                log.debug(f"{name}: status OK")
            else:
                log.debug(f"{name}: status=0x{status:08X}")
            return result

        val = self._extract_byte_at(data, 2)
        if val is not None and val in (0, 1):
            result = {"enabled": val == 1}
            log.debug(f"{name}: {'On' if result['enabled'] else 'Off'}")
            return result

        tlvs = parse_tlv(data)
        for tlv in tlvs:
            if len(tlv["value"]) == 1 and tlv["value"][0] in (0, 1):
                result = {"enabled": tlv["value"][0] == 1}
                log.debug(
                    f"{name}: {'On' if result['enabled'] else 'Off'} "
                    f"(from TLV tag {tlv['tag']})"
                )
                return result

        log.warning(
            f"{name}: unrecognized response format (data={data.hex()})"
        )
        return {"raw": data.hex()}

    def get_greet_setting(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_GREET),
            0x2B,
            0x0F,
            0x0E,
            "Greet (voice prompt)",
        )

    def set_greet(self, enable: bool) -> dict | None:
        result = self._send_bool_setter(
            Cmd.set_greet(enable), 0x2B, 0x0E, "Greet (voice prompt)", enable
        )
        return result

    def get_wear_setting(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_WEAR), 0x2B, 0x11, 0x10, "Wear detection"
        )

    def set_wear(self, enable: bool) -> dict | None:
        result = self._send_bool_setter(
            Cmd.set_wear(enable), 0x2B, 0x10, "Wear detection", enable
        )
        return result

    def get_intellect_volume(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_INTELLECT_VOLUME),
            0x2B,
            0x23,
            0x22,
            "Intellect volume",
        )

    def set_intellect_volume(self, enable: bool) -> dict | None:
        result = self._send_bool_setter(
            Cmd.set_intellect_volume(enable),
            0x2B,
            0x22,
            "Intellect volume",
            enable,
        )
        return result

    def get_saving_mode(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_SAVING_MODE),
            0x2B,
            0x1D,
            0x1C,
            "Saving mode",
        )

    def set_saving_mode(self, enable: bool) -> dict | None:
        result = self._send_bool_setter(
            Cmd.set_saving_mode(enable), 0x2B, 0x1C, "Saving mode", enable
        )
        return result

    def _parse_touch_get(
        self, frames: list[dict], svc: int, cmd: int, name: str, actions: dict
    ) -> dict | None:

        f = self._match_frame(frames, svc, cmd)
        if not f:
            log.warning(f"No {name} response")
            return None

        data = f["data"]

        status = self._parse_status_code(data)
        if status is not None:
            if status == 100000:
                log.debug(f"{name}: not configured (status=OK, value=100000)")
            else:
                log.debug(
                    f"{name}: status response code={status} (0x{status:08X})"
                )
            return {
                "status": status,
                "status_ok": status == 100000,
                "raw": data.hex(),
            }

        result = {"raw": data.hex()}
        found = False
        for tlv in parse_tlv(data):
            v = tlv["value"]
            if tlv["tag"] == 1 and len(v) == 1:
                result["left"] = v[0]
                result["left_name"] = actions.get(v[0], f"Unknown ({v[0]})")
                found = True
            elif tlv["tag"] == 2 and len(v) == 1:
                result["right"] = v[0]
                result["right_name"] = actions.get(v[0], f"Unknown ({v[0]})")
                found = True
            elif tlv["tag"] == 3:
                result["supported"] = list(v)
                result["supported_names"] = [
                    actions.get(b, f"Unknown ({b})")
                    for b in result["supported"]
                ]
                found = True
            elif tlv["tag"] == 4 and len(v) == 1:
                result["call_action"] = v[0]
                found = True
            elif tlv["tag"] == 6:
                result["call_supported"] = list(v)
                found = True

        if found:
            log.debug(f"{name}: {result}")
            return result

        log.warning(
            f"{name}: unrecognized response format (data={data.hex()})"
        )
        return None

    def _send_touch_set(
        self,
        cmd_payload: bytes,
        svc: int,
        cmd: int,
        name: str,
        side: int,
        action: int,
        actions: dict,
    ) -> dict | None:

        frames = self.send_command(cmd_payload)
        f = self._match_frame(frames, svc, cmd)
        if not f:
            log.warning(f"No {name} set response")
            return None

        data = f["data"]
        side_name = {0: "Both", 1: "Left", 2: "Right"}[side]
        action_name = actions.get(action, f"Unknown ({action})")
        result = {
            "side": side,
            "side_name": side_name,
            "action": action,
            "action_name": action_name,
        }

        status = self._parse_status_code(data)
        if status is not None:
            ok = status == 100000
            result["success"] = ok
            result["status"] = status
            if ok:
                log.debug(f"{name}: {side_name} -> {action_name}")
            else:
                log.warning(f"{name}: set failed (status=0x{status:08X})")
            return result

        for tlv in parse_tlv(data):
            if (
                tlv["tag"] == (6 if cmd_payload[2] == 4 else 3)
                and len(tlv["value"]) == 1
            ):
                code = tlv["value"][0]
                ok = (
                    code in (0, 2)
                    if side == 0
                    else code == (2 if side == SIDE_RIGHT else 0)
                )
                result["success"] = ok
                result["result"] = code
                result["result_name"] = ACTION_RESULT.get(
                    code, f"Unknown ({code})"
                )
                if ok:
                    log.debug(
                        f"{name}: {side_name} -> {action_name} "
                        f"(result={ACTION_RESULT.get(code)})"
                    )
                else:
                    log.warning(
                        f"{name}: set failed ({ACTION_RESULT.get(code, code)})"
                    )
                return result

        echo = self._extract_tlv_value(data, cmd_payload[2])
        if echo and len(echo) == 1:
            resp_action = echo[0]
            result["success"] = resp_action == action
            if result["success"]:
                log.debug(f"{name}: {side_name} -> {action_name}")
            else:
                log.warning(
                    f"{name}: set may have failed (resp={resp_action})"
                )
            return result

        result["success"] = None
        log.warning(f"{name}: unrecognized set response (resp={data.hex()})")
        return result

    def _send_bool_setter(
        self, cmd_payload: bytes, svc: int, cmd: int, name: str, enable: bool
    ) -> dict | None:

        frames = self.send_command(cmd_payload)
        f = self._match_frame(frames, svc, cmd)
        if not f:
            log.warning(f"No {name} set response")
            return None

        data = f["data"]

        status = self._parse_status_code(data)
        if status is not None:
            ok = status == 100000
            result = {"enabled": enable, "success": ok, "status": status}
            if ok:
                log.info(f"{name}: set to {'On' if enable else 'Off'}")
            else:
                log.warning(f"{name}: set failed (status=0x{status:08X})")
            return result

        return {"enabled": enable, "success": None, "raw": data.hex()}

    def _get_touch_gesture(self, key: str) -> dict | None:
        gtype = GESTURE_TYPES[key]
        state = self._parse_touch_get(
            self.send_command(gtype["get"] + b"\x03\x00"),
            gtype["svc"],
            gtype["cmd"],
            gtype["name"],
            gtype["actions"],
        )

        if state and "supported" in state:
            advertised = state["supported"]
            state["advertised"] = advertised
            state["supported"] = [
                v
                for v in gtype["actions"]
                if v in advertised or (key == "long_press" and v == 255)
            ]
            state["supported_names"] = [
                gtype["actions"][v] for v in state["supported"]
            ]
        if state and key in CALL_ACTIONS and "call_action" in state:
            state["call_name"] = CALL_ACTIONS[key].get(
                state["call_action"], "Unknown"
            )
        if key == "slide" and state and "left" in state:
            state["global"] = state.pop("left")
            state["global_name"] = state.pop("left_name")
            state.pop("right", None)
            state.pop("right_name", None)
        return state

    def set_call_gesture(self, gesture: str, action: int) -> dict | None:
        key = GESTURE_ALIASES.get(gesture.lower())
        if key not in CALL_SETTERS:
            return None
        state = self._get_touch_gesture(key)
        if (
            not state
            or action not in CALL_ACTIONS[key]
            or action not in state.get("call_supported", ())
        ):
            return None
        entry = GESTURE_TYPES[key]
        result = self._send_touch_set(
            CALL_SETTERS[key](action),
            entry["svc"],
            entry["set_cmd"],
            entry["name"],
            0,
            action,
            CALL_ACTIONS[key],
        )

        if result and result.get("success") is not False:
            observed = self._get_touch_gesture(key) or {}
            result["success"] = observed.get("call_action") == action
        return result

    def _set_touch_gesture(
        self, key: str, side: int, action: int
    ) -> dict | None:
        gtype = GESTURE_TYPES[key]
        left = action if side in (0, SIDE_LEFT) else None
        right = action if side == SIDE_RIGHT else None
        if key == "slide" and side == 0:
            payload = bytes([0x2B, 0x1E, 1, 1, action, 2, 2, action])
        else:
            payload = gtype["set"](left, right)
        result = self._send_touch_set(
            payload,
            gtype["svc"],
            gtype["set_cmd"],
            gtype["name"],
            side,
            action,
            gtype["actions"],
        )

        if result and result.get("success") is not False:
            observed = self._get_touch_gesture(key) or {}
            field = {0: "global", 1: "left", 2: "right"}[side]
            result["success"] = observed.get(field) == action
        return result

    def get_gesture_action(self, gesture_type: str) -> dict | None:
        key = GESTURE_ALIASES.get(gesture_type.lower())
        if not key:
            log.error(
                f"Unknown gesture '{gesture_type}'. "
                f"Valid: {', '.join(GESTURE_ALIASES)}"
            )
            return None
        return self._get_touch_gesture(key)

    def set_gesture_action(
        self, gesture_type: str, side: int, action: int
    ) -> dict | None:
        key = GESTURE_ALIASES.get(gesture_type.lower())
        if not key:
            log.error(
                f"Unknown gesture '{gesture_type}'. "
                f"Valid: {', '.join(GESTURE_ALIASES)}"
            )
            return None
        gtype = GESTURE_TYPES[key]
        state = self._get_touch_gesture(key)
        if not state or action not in state.get("supported", ()):
            log.error(
                f"{gtype['name']}: action {action} is unavailable "
                "for FreeBuds 5i"
            )
            return None
        if "global" in state:
            if side not in (0, SIDE_LEFT):
                return None
            side = 0
        elif {1: "left", 2: "right"}.get(side) not in state:
            return None
        return self._set_touch_gesture(key, side, action)

    def get_long_press_action(self) -> dict | None:
        return self._get_touch_gesture("long_press")

    def set_long_press_action(self, side: int, action: int) -> dict | None:
        return self.set_gesture_action("long_press", side, action)

    def get_triple_click_action(self) -> dict | None:
        return self._get_touch_gesture("triple_click")

    def set_triple_click_action(
        self, side: int, action: int
    ) -> dict | None:
        return self.set_gesture_action("triple_click", side, action)

    def get_slide_action(self) -> dict | None:
        return self._get_touch_gesture("slide")

    def set_slide_action(self, side: int, action: int) -> dict | None:
        return self.set_gesture_action("slide", side, action)

    def get_double_click_action(self) -> dict | None:
        return self._get_touch_gesture("double_click")

    def set_double_click_action(
        self, side: int, action: int
    ) -> dict | None:
        return self.set_gesture_action("double_click", side, action)

    def set_noise_control_gesture(
        self, gesture_type: str, side: int
    ) -> dict | None:
        key = GESTURE_ALIASES.get(gesture_type.lower())
        if not key:
            log.error(
                f"Unknown gesture '{gesture_type}'. "
                f"Valid: {', '.join(GESTURE_ALIASES)}"
            )
            return None
        nc_action = ACTION_NOISE_CONTROL.get(key)
        if nc_action is None:
            log.error(
                f"{GESTURE_TYPES[key]['name']} has no noise-control action"
            )
            return None
        return self.set_gesture_action(key, side, nc_action)

    def get_noise_control_status(self) -> dict:
        result: dict[str, Any] = {"noise_control_assigned": [], "details": {}}
        for gkey, gtype in GESTURE_TYPES.items():
            resp = self._get_touch_gesture(gkey)
            result["details"][gkey] = resp
            nc_action = ACTION_NOISE_CONTROL.get(gkey)
            if resp and nc_action is not None:
                for side_key in ("left", "right"):
                    if resp.get(side_key) == nc_action:
                        result["noise_control_assigned"].append(
                            {
                                "gesture": gkey,
                                "gesture_name": gtype["name"],
                                "side": SIDE_LEFT
                                if side_key == "left"
                                else SIDE_RIGHT,
                                "side_name": "Left"
                                if side_key == "left"
                                else "Right",
                            }
                        )
        nc = result["noise_control_assigned"]
        if nc:
            log.debug(f"Noise control assigned to {len(nc)} gesture(s):")
            for g in nc:
                log.debug(f"  {g['gesture_name']} ({g['side_name']})")
        else:
            log.debug("No gesture currently assigned to noise control")
        return result

    def get_feature(self, feat: str) -> dict | None:
        entry = FEATURES.get(feat)
        if not entry:
            log.error(
                f"Unknown feature '{feat}'. Valid: {', '.join(FEATURES)}"
            )
            return None
        return getattr(self, entry["get"])()

    def set_feature(self, feat: str, enable: bool) -> dict | None:
        entry = FEATURES.get(feat)
        if not entry:
            log.error(
                f"Unknown feature '{feat}'. Valid: {', '.join(FEATURES)}"
            )
            return None
        setter = entry.get("set")
        if not setter:
            log.error(f"{entry['name']} is read-only")
            return None
        result = getattr(self, setter)(enable)
        if result and result.get("success") is None:
            result["success"] = (self.get_feature(feat) or {}).get(
                "enabled"
            ) is enable
        return result

    def start_pair(self) -> dict | None:
        frames = self.send_command(Cmd.STATE_PAIR)
        f = self._match_frame(frames, 0x2B, 0x90)
        if not f:
            log.warning("No pair-state set response")
            return None
        data = f["data"]
        result = {"raw": data.hex()}
        status = self._parse_status_code(data)
        if status is not None:
            result["success"] = status == 100000
            result["status"] = status
            if result["success"]:
                log.debug("Pair state: entering pairing")
            else:
                log.warning(f"Pair state: set failed (status=0x{status:08X})")
        else:
            result["success"] = True
            log.debug("Pair state: entering pairing")
        return result

    def _parse_uint_get(
        self, frames: list[dict], svc: int, cmd: int, name: str
    ) -> dict | None:

        f = self._match_frame(frames, svc, cmd)
        if not f:
            log.warning(f"No {name} response")
            return None
        data = f["data"]
        result = {"raw": data.hex()}
        status = self._parse_status_code(data)
        if status is not None:
            result["status"] = status
            result["status_ok"] = status == 100000
            if result["status_ok"]:
                log.debug(f"{name}: status OK")
            else:
                log.debug(f"{name}: status=0x{status:08X}")
            return result
        val = self._extract_tlv_value(data, 1)
        if val is not None:
            result["value"] = int.from_bytes(val, "big")
            log.debug(f"{name}: value={result['value']}")
            return result
        b = self._extract_byte_at(data, 2)
        if b is not None:
            result["value"] = b
            log.debug(f"{name}: value={b}")
            return result
        log.warning(f"{name}: unrecognized response (data={data.hex()})")
        return result

    def get_game_low_latency(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_GAME_LOW_LATENCY),
            0x2B,
            0x6C,
            0x6C,
            "Game low latency",
        )

    def set_game_low_latency(self, enable: bool) -> dict | None:
        return self._send_bool_setter(
            Cmd.set_game_low_latency(enable),
            0x2B,
            0x6C,
            "Game low latency",
            enable,
        )

    def get_dual_connect(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_DUAL_CONNECT),
            0x2B,
            0x2F,
            0x2E,
            "Dual connect",
        )

    def set_dual_connect(self, enable: bool) -> dict | None:
        return self._send_bool_setter(
            Cmd.set_dual_connect(enable), 0x2B, 0x2E, "Dual connect", enable
        )

    def get_translate_mode(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_TRANSLATE_MODE),
            0x2B,
            0x4D,
            0x4C,
            "Translate mode",
        )

    def set_translate_mode(self, enable: bool) -> dict | None:
        return self._send_bool_setter(
            Cmd.set_translate_mode(enable),
            0x2B,
            0x4C,
            "Translate mode",
            enable,
        )

    def get_voice_enhance(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_VOICE_ENHANCE),
            0x2B,
            0x42,
            0x41,
            "Voice enhance",
        )

    def set_voice_enhance(self, enable: bool) -> dict | None:
        return self._send_bool_setter(
            Cmd.set_voice_enhance(enable), 0x2B, 0x41, "Voice enhance", enable
        )

    def get_32k_hd(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_32K_HD), 0x2B, 0x46, 0x45, "32K HD voice"
        )

    def set_32k_hd(self, enable: bool) -> dict | None:
        return self._send_bool_setter(
            Cmd.set_32k_hd(enable), 0x2B, 0x45, "32K HD voice", enable
        )

    def get_hd_switch(self) -> dict | None:
        frame = self._match_frame(
            self.send_command(Cmd.GET_HD_SWITCH), 0x2B, 0xA3
        )
        if frame:
            value = self._extract_tlv_value(frame["data"], 2)
            if value in (b"\x00", b"\x01"):
                return {"enabled": value == b"\x01"}
        return None

    def set_hd_switch(self, enable: bool) -> dict | None:
        return self._send_bool_setter(
            Cmd.set_hd_switch(enable),
            0x2B,
            0xA2,
            "Prioritize sound quality",
            enable,
        )

    def locator(self, side, ring=None):
        if side not in ("left", "right"):
            raise ValueError("Choose left or right")
        index = int(side == "right")
        if ring is not None:
            if ring:
                wear = self.get_wearing_status() or {}
                if any(wear.get(side + "_ear") != 0 for side in ("left", "right")):
                    return {
                        "success": False,
                        "error": "Take both earbuds out before ringing them",
                    }
            cmd = bytes((0x2B, 0x5D, 1, 2, index, int(not ring)))
            frame = self._match_frame(self.send_command(cmd), 0x2B, 0x5D)
            if frame and self._parse_status_code(frame["data"]) not in (
                None,
                100000,
            ):
                return {
                    "success": False,
                    "status": self._parse_status_code(frame["data"]),
                }
        cmd = bytes((0x2B, 0x5E, 1, 1, index))
        frame = self._match_frame(self.send_command(cmd), 0x2B, 0x5E)
        value = self._extract_tlv_value(frame["data"], 2) if frame else None
        if (
            value is None
            or len(value) != 2
            or value[0] != index
            or value[1] not in (0, 1)
        ):
            return None
        ringing = value[1] == 0
        return {"ringing": ringing, "success": ring is None or ringing == ring}

    def get_left_right_ear(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_LEFT_RIGHT_EAR),
            0x2B,
            0x9A,
            0x99,
            "L/R ear recognition",
        )

    def set_left_right_ear(self, enable: bool) -> dict | None:
        return self._send_bool_setter(
            Cmd.set_left_right_ear(enable),
            0x2B,
            0x99,
            "L/R ear recognition",
            enable,
        )

    def get_wind_mode(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_WIND_MODE), 0x2B, 0x95, 0x94, "Wind mode"
        )

    def set_wind_mode(self, enable: bool) -> dict | None:
        return self._send_bool_setter(
            Cmd.set_wind_mode(enable), 0x2B, 0x94, "Wind mode", enable
        )

    def get_silent_upgrade(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_SILENT_UPGRADE),
            0x2B,
            0x70,
            0x6F,
            "Silent upgrade",
        )

    def set_silent_upgrade(self, enable: bool) -> dict | None:
        return self._send_bool_setter(
            Cmd.set_silent_upgrade(enable),
            0x2B,
            0x6F,
            "Silent upgrade",
            enable,
        )

    def get_health_alerts(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_HEALTH_ALERTS),
            0x2B,
            0x61,
            0x60,
            "Health alerts",
        )

    def set_health_alerts(self, enable: bool) -> dict | None:
        return self._send_bool_setter(
            Cmd.set_health_alerts(enable), 0x2B, 0x60, "Health alerts", enable
        )

    def get_wearing_status(self) -> dict | None:
        frames = self.send_command(Cmd.GET_WEARING_STATUS)
        f = self._match_frame(frames, 0x2B, 0x25)
        if not f:
            log.warning("No wearing status response")
            return None
        data = f["data"]
        result = {"raw": data.hex()}
        status = self._parse_status_code(data)
        if status is not None:
            result["status"] = status
            result["status_ok"] = status == 100000
            log.debug(f"Wearing status: status=0x{status:08X}")
            return result
        for tlv in parse_tlv(data):
            v = tlv["value"]
            if tlv["tag"] == 1 and len(v) == 1:
                result["left_ear"] = v[0]
                result["left_in"] = v[0] == 1
            elif tlv["tag"] == 2 and len(v) == 1:
                result["right_ear"] = v[0]
                result["right_in"] = v[0] == 1
        log.debug(f"Wearing status: {result}")
        return result

    def get_dormant_time(self) -> dict | None:
        return self._parse_uint_get(
            self.send_command(Cmd.GET_DORMANT_TIME), 0x2B, 0x48, "Dormant time"
        )

    def set_dormant_time(self, option: int, seconds: int) -> dict | None:
        frames = self.send_command(Cmd.set_dormant_time(option, seconds))
        f = self._match_frame(frames, 0x2B, 0x47)
        if not f:
            log.warning("No dormant time set response")
            return None
        data = f["data"]
        result = {"option": option, "seconds": seconds}
        status = self._parse_status_code(data)
        if status is not None:
            result["success"] = status == 100000
            result["status"] = status
            if result["success"]:
                log.debug(f"Dormant time: set to {seconds}s")
            else:
                log.warning(
                    f"Dormant time: set failed (status=0x{status:08X})"
                )
        else:
            result["success"] = True
            log.debug(f"Dormant time: set to {seconds}s")
        return result

    def get_pair_state(self) -> dict | None:
        return self._parse_uint_get(
            self.send_command(Cmd.QUERY_PAIR), 0x2B, 0x8F, "Pair state"
        )

    def run_fit_test(self) -> dict:
        if not shutil.which("paplay") or not shutil.which("pactl"):
            return {
                "success": False,
                "error": "Fit test requires paplay and pactl",
            }
        if not self._connected or not self.mac_address:
            return {"success": False, "error": "FreeBuds disconnected"}
        sinks = subprocess.check_output(
            ["pactl", "list", "short", "sinks"], text=True, timeout=5
        )
        address = self.mac_address.replace(":", "_").replace("-", "_").lower()
        sink = next(
            (
                fields[1]
                for row in sinks.splitlines()
                if len(fields := row.split()) >= 2
                and address in fields[1].lower()
                and "bluez" in fields[1].lower()
                and "headset" not in fields[1].lower()
            ),
            None,
        )
        if not sink:
            return {
                "success": False,
                "error": "FreeBuds playback sink unavailable",
            }
        audio = fit_audio()
        with self._lock:
            wearing = self.get_wearing_status() or {}
            if not (wearing.get("left_in") and wearing.get("right_in")):
                return {
                    "success": False,
                    "error": "Wear both buds for the fit test",
                }
            version = self.get_fit_detect_version() or {}
            volume_steps = 15 if version.get("value") == 1 else 8
            player = None
            try:
                frames = self.send_command(Cmd.GET_FIT_CHECK, 0.5)
                ack = self._match_frame(frames, 0x2B, 0x26)
                if not ack or self._extract_tlv_value(ack["data"], 2) != bytes(
                    [0]
                ):
                    return {
                        "success": False,
                        "error": "Fit test start was not confirmed",
                    }
                player = subprocess.Popen(
                    [
                        "paplay",
                        "--device",
                        sink,
                        "--volume",
                        str(65536 * volume_steps // 15),
                        str(audio),
                    ]
                )
                received = b""
                parsed_count = 0
                deadline = time.monotonic() + 10
                result = {}
                while True:
                    for frame in frames:
                        if frame["svc"] == 0x2B and frame["cmd"] == 0x27:
                            value = self._extract_tlv_value(frame["data"], 1)
                            if value in (b"\x04", b"\x05"):
                                return {
                                    "success": False,
                                    "error": "Acoustic interference",
                                }
                            if value in (b"\x00", b"\x01", b"\x02", b"\x03"):
                                result["left" if value[0] < 2 else "right"] = (
                                    "good" if value[0] in (0, 2) else "adjust"
                                )
                    playback = player.poll()
                    if playback not in (0, None):
                        return {
                            "success": False,
                            "error": "Test audio playback failed",
                        }
                    if playback == 0 and len(result) == 2:
                        return {"success": True, **result}
                    if time.monotonic() >= deadline:
                        break
                    if self.sock is None:
                        break
                    self.sock.settimeout(0.25)
                    try:
                        chunk = self.sock.recv(4096)
                        if not chunk:
                            break
                        received += chunk
                    except TimeoutError:
                        pass
                    parsed = parse_frames(received)
                    frames = [f for f in parsed[parsed_count:] if f["crc_ok"]]
                    parsed_count = len(parsed)
                return {
                    "success": False,
                    "error": "Incomplete fit report",
                    **result,
                }
            finally:
                try:
                    if player is not None and player.poll() is None:
                        player.terminate()
                        try:
                            player.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            player.kill()
                            player.wait()
                finally:
                    self.exit_fit_check()

    def get_fit_check(self) -> dict | None:
        return self._parse_uint_get(
            self.send_command(Cmd.GET_FIT_CHECK),
            0x2B,
            0x26,
            "Earplug fit check",
        )

    def exit_fit_check(self) -> dict | None:
        frames = self.send_command(Cmd.EXIT_FIT_CHECK)
        f = self._match_frame(frames, 0x2B, 0x26)
        if not f:
            log.warning("No fit-check exit response")
            return None
        data = f["data"]
        result = {"raw": data.hex()}
        status = self._parse_status_code(data)
        if status is not None:
            result["success"] = status == 100000
            result["status"] = status
        else:
            result["success"] = self._extract_tlv_value(data, 2) == bytes([2])
        log.debug(f"Fit-check exit: {result}")
        return result

    def get_fit_detect_version(self) -> dict | None:
        return self._parse_uint_get(
            self.send_command(Cmd.GET_FIT_DETECT_VERSION),
            0x2B,
            0x37,
            "Fit-detect version",
        )

    def get_heartbeat(self) -> dict | None:
        return self._parse_uint_get(
            self.send_command(Cmd.HEARTBEAT), 0x2B, 0x4E, "Heartbeat"
        )

    def get_bt_main_status(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_BT_MAIN_STATUS),
            0x2B,
            0x6A,
            0x6A,
            "BT main status",
        )

    def get_close_cover_remind(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_CLOSE_COVER_REMIND),
            0x2B,
            0x7F,
            0x7F,
            "Close-cover remind",
        )

    def get_music_mode(self) -> dict | None:
        return self._parse_uint_get(
            self.send_command(Cmd.GET_MUSIC_MODE), 0x2B, 0x53, "Music mode"
        )

    def get_ambient_sound(self) -> dict | None:
        return self._parse_bool_get(
            self.send_command(Cmd.GET_AMBIENT_SOUND),
            0x2B,
            0x2C,
            0x2C,
            "Ambient sound",
        )

    def get_connect_ability(self) -> dict | None:
        return self._parse_uint_get(
            self.send_command(Cmd.GET_CONNECT_ABILITY),
            0x2B,
            0x2D,
            "Connect ability",
        )

    def _parse_bonded_device(self, data: bytes) -> dict:
        dev = {}
        for tlv in parse_tlv(data):
            v = tlv["value"]
            tag = tlv["tag"]
            if tag == 2 and len(v) == 1:
                dev["number"] = v[0]
            elif tag == 3 and len(v) == 1:
                dev["index"] = v[0]
            elif tag == 4 and len(v) == 6:
                dev["addr"] = mac_to_str(v)
                dev["byte_addr"] = v
            elif tag == 5 and len(v) == 1:
                dev["conn_state"] = v[0] & 1
                dev["business_state"] = (v[0] & 0x0E) >> 1
                dev["in_business"] = ((v[0] & 0x0E) >> 1) > 1
            elif tag == 6 and len(v) == 1:
                dev["type"] = v[0]
            elif tag == 7 and len(v) == 1:
                dev["primary"] = v[0]
            elif tag == 8 and len(v) == 1:
                dev["back_conn_permit"] = v[0]
            elif tag == 9 and v:
                dev["name"] = (
                    v.decode("utf-8", errors="ignore").strip().rstrip("\x00")
                )
            elif tag == 10 and len(v) == 1:
                dev["allow_audio_auto_switch"] = v[0] == 1
            elif tag == 11 and len(v) == 1:
                dev["nearlink"] = v[0] == 1
            elif tag in (13, 15) and len(v) == 1:
                dev["lock_channel"] = v[0] == 1
        return dev

    def _parse_device_report(self, data: bytes) -> dict:
        rep = {}
        for tlv in parse_tlv(data):
            v = tlv["value"]
            tag = tlv["tag"]
            rep["type"] = tag
            if tag == 1:
                rep["indices"] = [b for b in v if b != 0xFF]
            elif tag == 2 and len(v) == 6:
                rep["addr"] = mac_to_str(v)
            elif tag == 3 and len(v) == 1:
                rep["flag"] = v[0] == 1
            elif tag == 4 and len(v) == 6:
                rep["byte_addr"] = v
                rep["addr"] = mac_to_str(v)
            elif tag == 5 and len(v) == 7:
                rep["addr"] = mac_to_str(v[:6])
                rep["conn_state"] = v[6] & 1
                rep["business_state"] = (v[6] & 0x0E) >> 1
                rep["in_business"] = ((v[6] & 0x0E) >> 1) > 1
            elif tag == 6 and len(v) == 7:
                rep["addr"] = mac_to_str(v[:6])
                rep["back_conn_permit"] = v[6]
            elif tag == 7 and len(v) == 6:
                rep["addr"] = mac_to_str(v)
            elif tag == 8 and len(v) == 7:
                rep["addr"] = mac_to_str(v[:6])
                rep["allow_audio_auto_switch"] = v[6] == 1
            elif tag == 9 and len(v) == 7:
                rep["addr"] = mac_to_str(v[:6])
                rep["lock_channel"] = v[6] == 1
        return rep

    def get_bonded_devices(self, timeout: float = 2.0) -> list[dict]:
        frames = self.send_command(Cmd.GET_DEVICES_BONDED, timeout)
        devices = {}
        for f in frames:
            if f["svc"] != 0x2B:
                continue
            if f["cmd"] == 0x31:
                dev = self._parse_bonded_device(f["data"])
                if dev.get("addr"):
                    devices[dev["addr"]] = dev
            elif f["cmd"] == 0x36:
                rep = self._parse_device_report(f["data"])
                addr = rep.get("addr")
                if not addr or addr not in devices:
                    continue
                dev = devices[addr]
                if rep.get("type") == 5:
                    dev["conn_state"] = rep["conn_state"]
                    dev["business_state"] = rep.get("business_state")
                    dev["in_business"] = rep.get("in_business", False)
                elif rep.get("type") == 6:
                    dev["back_conn_permit"] = rep["back_conn_permit"]
                elif rep.get("type") == 8:
                    dev["allow_audio_auto_switch"] = rep[
                        "allow_audio_auto_switch"
                    ]
                elif rep.get("type") == 9:
                    dev["lock_channel"] = rep["lock_channel"]
        result = list(devices.values())
        result.sort(key=lambda d: d.get("index", 255))
        log.debug(f"Bonded devices: {len(result)}")
        for d in result:
            log.debug(
                f"  [{d.get('index')}] {d.get('name', '?')} {d.get('addr')} "
                f"state={d.get('conn_state')} primary={d.get('primary')}"
            )
        return result

    def _resolve_bonded_mac(
        self, target: str, timeout: float = 2.0
    ) -> str | None:
        mac = target.strip().upper().replace("-", ":")
        if re.match(r"^([0-9A-F]{2}:){5}[0-9A-F]{2}$", mac):
            return mac
        try:
            index = int(target)
        except ValueError:
            log.warning(
                f"Device target must be a MAC or index, got '{target}'"
            )
            return None
        for d in self.get_bonded_devices(timeout):
            if d.get("index") == index:
                return d["addr"]
        log.warning(f"No bonded device with index {index}")
        return None

    def _parse_type_operate_result(self, data: bytes) -> dict | None:
        result = {}
        for tlv in parse_tlv(data):
            if tlv["tag"] == 30 and len(tlv["value"]) == 1:
                result["type"] = tlv["value"][0]
            elif tlv["tag"] == 31 and len(tlv["value"]) == 1:
                result["result"] = tlv["value"][0]
        if result:
            return result
        status = self._parse_status_code(data)
        if status is not None:
            return {"type": None, "result": status}
        return None

    def _send_single_device_setting(
        self, sub: int, mac: str
    ) -> dict | None:
        mac_bytes = mac_to_bytes(mac)
        if len(mac_bytes) != 6:
            log.warning(f"Invalid MAC: {mac}")
            return None
        frames = self.send_command(Cmd.single_device_setting(sub, mac_bytes))
        for f in frames:
            if f["svc"] == 0x2B and f["cmd"] == 0x33:
                res = self._parse_type_operate_result(f["data"])
                if res:
                    return {
                        "mac": mac,
                        "sub": sub,
                        **res,
                        "success": res.get("result") in (0, 100000)
                        and res.get("type") in (None, sub),
                    }
        if frames:
            return {"mac": mac, "sub": sub, "type": None, "result": None}
        return None

    def connect_device(self, mac: str) -> dict | None:
        return self._send_single_device_setting(1, mac)

    def disconnect_device(self, mac: str) -> dict | None:
        return self._send_single_device_setting(2, mac)

    def unpair_device(self, mac: str) -> dict | None:
        return self._send_single_device_setting(3, mac)

    def set_device_preference(
        self, mac: str, preference: str, enabled: bool
    ) -> dict | None:
        options = {
            "reconnect": ("back_conn_permit", 4, 5),
            "audio-switch": ("allow_audio_auto_switch", 6, 7),
        }
        if preference not in options or type(enabled) is not bool:
            return None
        field, on, off = options[preference]
        device = next(
            (
                d
                for d in self.get_bonded_devices()
                if d["byte_addr"] == mac_to_bytes(mac)
            ),
            {},
        )
        if field not in device:
            return {
                "success": False,
                "error": "Device does not advertise this preference",
            }
        return self._send_single_device_setting(on if enabled else off, mac)

    def set_primary_device(self, mac: str) -> dict | None:
        mac_bytes = mac_to_bytes(mac)
        if len(mac_bytes) != 6:
            log.warning(f"Invalid MAC: {mac}")
            return None
        frames = self.send_command(Cmd.set_primary_device(mac_bytes))
        if not frames:
            return None
        f = self._match_frame(frames, 0x2B, 0x32)
        if f:
            status = self._parse_status_code(f["data"])
            if status is not None:
                return {
                    "mac": mac,
                    "success": status == 100000,
                    "status": status,
                }
            success = any(
                d["byte_addr"] == mac_bytes and d.get("primary") == 1
                for d in self.get_bonded_devices()
            )
            return {"mac": mac, "success": success}
        return {"mac": mac, "success": None, "raw": frames[0]["data"].hex()}

    def _find_anc_mode(self, data: bytes) -> int | None:
        if self._is_status_response(data):
            return None
        val = self._extract_tlv_value(data, 1)
        if val:
            if len(val) == 1 and val[0] in NC_MODES:
                return val[0]
            if len(val) == 2 and val[1] in NC_MODES:
                return val[1]
            return None
        if parse_tlv(data):
            return None
        b = self._extract_byte_at(data, 2)
        if b is not None and b in NC_MODES:
            return b
        return None

    def get_anc_state(self) -> dict | None:
        frames = self.send_command(Cmd.GET_ANC_STATE)
        f = self._match_frame(frames, 0x2B, 0x05)
        if not f:
            log.warning("No ANC state response")
            return None
        data = f["data"]
        result = {"raw": data.hex(), "source": "anc_state"}
        status = self._parse_status_code(data)
        if status is not None:
            result["status"] = status
            result["status_ok"] = status in (0, 100000)
            if result["status_ok"]:
                log.debug("ANC state: status OK")
            else:
                log.debug(f"ANC state: status=0x{status:08X}")
            return result
        mode = self._find_anc_mode(data)
        if mode is not None:
            result["mode"] = mode
            result["mode_name"] = NC_MODES[mode]
            val = self._extract_tlv_value(data, 1)
            if val and len(val) == 2 and mode == NC_MODE_ON:
                level = val[0]
                result["level"] = level
                result["level_name"] = NC_LEVELS.get(
                    level, f"Unknown ({level})"
                )
            log.debug(f"ANC state: {NC_MODES[mode]}")
            return result
        log.warning(f"ANC state: unrecognized response (data={data.hex()})")
        return result

    def get_anc_mode_level(self) -> dict | None:
        frames = self.send_command(Cmd.GET_ANC_MODE_LEVEL)
        f = self._match_frame(frames, 0x2B, 0x07)
        if not f:
            log.warning("No ANC mode+level response")
            return None
        data = f["data"]
        result = {"raw": data.hex(), "source": "anc_mode_level"}
        for tlv in parse_tlv(data):
            v = tlv["value"]
            if tlv["tag"] == 1 and len(v) == 1:
                result["mode"] = v[0]
                result["mode_name"] = NC_MODES.get(v[0], f"Unknown ({v[0]})")
            elif tlv["tag"] == 2 and len(v) == 1:
                result["common_index"] = v[0]
                result["level_name"] = NC_LEVELS.get(v[0], f"Unknown ({v[0]})")
            elif tlv["tag"] == 3 and len(v) == 1:
                result["plane_index"] = v[0]
            elif tlv["tag"] == 4 and len(v) == 1:
                result["fly_mode"] = v[0]
            elif tlv["tag"] == 5 and len(v) == 2:
                result["mode_scene"] = v[0]
                result["mode_voice"] = v[1] & 0x03
                result["mode_noise"] = (v[1] & 0x3C) >> 2
        if "mode" in result:
            log.debug(
                f"ANC mode+level: mode={result['mode_name']} "
                f"common={result.get('common_index')} "
                f"plane={result.get('plane_index')}"
            )
        return result

    def get_dynamic_anc_support(self) -> dict | None:
        reply = self._match_frame(
            self.send_command(bytes.fromhex("2b2b0300")), 0x2B, 0x2B
        )
        if reply:
            value = self._extract_tlv_value(reply["data"], 1)
            if value in (bytes([0]), bytes([1])):
                return {"supported": bool(value[0])}
        return None

    def query_noise_reduction_mode(self) -> dict | None:
        frames = self.send_command(Cmd.QUERY_NOISE_REDUCTION_MODE)
        f = self._match_frame(frames, 0x2B, 0x2A)
        if not f:
            log.warning("No noise reduction mode response")
            return None
        data = f["data"]
        result = {"raw": data.hex(), "source": "query_nr_mode"}
        for tlv in parse_tlv(data):
            v = tlv["value"]
            if tlv["tag"] == 1 and len(v) == 2:
                result["submode"] = v[0]
                if v[1] == NC_MODE_ON:
                    result["level"] = v[0]
                    result["level_name"] = NC_LEVELS.get(
                        v[0], f"Unknown ({v[0]})"
                    )
                if v[1] == NC_MODE_AWARE:
                    result["awareness_name"] = {
                        1: "Voice enhanced",
                        2: "Awareness",
                        4: "Smart awareness",
                    }.get(v[0], "Unknown")
                result["mode"] = v[1]
                result["mode_name"] = NC_MODES.get(v[1], f"Unknown ({v[1]})")
            elif tlv["tag"] == 2 and len(v) == 1:
                result["extra"] = v[0]
        if "mode" in result:
            log.debug(
                f"Noise reduction mode: {result['mode_name']} "
                f"(level={result.get('level')})"
            )
        return result

    def get_noise_control_setting(self) -> dict | None:
        frames = self.send_command(Cmd.GET_NOISE_CONTROL)
        f = self._match_frame(frames, 0x2B, 0x19)
        if not f:
            log.warning("No noise control (2B 19) response")
            return None
        data = f["data"]
        result = {}
        for tlv in parse_tlv(data):
            tag, value = tlv["tag"], tlv["value"]
            if tag in (1, 2) and len(value) == 1:
                side = "left" if tag == 1 else "right"
                result[side] = value[0]
                result[side + "_name"] = NOISE_CYCLES.get(value[0], "Unknown")
            elif tag == 3:
                result["supported"] = list(value)
        return result or None

    def get_noise_mode(self) -> dict | None:
        for method in (
            self.query_noise_reduction_mode,
            self.get_anc_state,
            self.get_anc_mode_level,
        ):
            r = method()
            if r and "mode" in r:
                return r
        return None

    def _parse_anc_status(self, data: bytes) -> int | None:
        status = self._parse_status_code(data)
        if status is not None:
            return status
        val = self._extract_tlv_value(data, 2)
        if val and len(val) == 1:
            return val[0]
        return None

    def _parse_anc_set_result(
        self, frames: list[dict], svc: int, cmd: int, mode: int, name: str
    ) -> dict | None:

        f = self._match_frame(frames, svc, cmd)
        if not f:
            log.warning(f"No {name} set response")
            return None
        data = f["data"]
        result = {
            "mode": mode,
            "mode_name": NC_MODES.get(mode, f"Unknown ({mode})"),
        }

        status = self._parse_anc_status(data)
        if status is not None:
            ok = status in (0, 100000)
            result["success"] = ok
            result["status"] = status
            if ok:
                log.debug(f"{name}: set to {NC_MODES.get(mode, mode)}")
            else:
                log.warning(f"{name}: set failed (status=0x{status:08X})")
            return result

        result["success"] = None
        log.warning(f"{name}: unrecognized set response (resp={data.hex()})")
        return result

    def set_anc_state(self, mode: int) -> dict | None:
        if mode not in NC_MODES:
            log.error(
                f"Invalid ANC mode {mode}. Valid: {list(NC_MODES.keys())}"
            )
            return None
        frames = self.send_command(Cmd.set_anc_state(mode))
        return self._parse_anc_set_result(
            frames, 0x2B, 0x04, mode, "ANC state"
        )

    def set_anc_state_extended(
        self, mode: int, level: int = 0xFF
    ) -> dict | None:
        if mode not in NC_MODES:
            log.error(
                f"Invalid ANC mode {mode}. Valid: {list(NC_MODES.keys())}"
            )
            return None
        if isinstance(level, str):
            level = resolve_anc_level(level)
            if level is None:
                log.error(
                    f"Invalid ANC level. Valid: "
                    f"{', '.join(NC_LEVELS.values())} "
                    "(0-3)"
                )
                return None
        if mode == NC_MODE_ON and level not in (*NC_LEVELS, 255):
            return None
        if mode == NC_MODE_OFF and level not in (0, 255):
            return None
        if mode == NC_MODE_AWARE and level not in (1, 2, 255):
            return None
        if (
            mode == NC_MODE_ON
            and level == NC_LEVEL_DYNAMIC
            and not (self.get_dynamic_anc_support() or {}).get("supported")
        ):
            return None
        frames = self.send_command(Cmd.set_anc_state_level(mode, level))
        return self._parse_anc_set_result(
            frames, 0x2B, 0x04, mode, "ANC state+level"
        )

    def set_anc_level(self, level: int) -> dict | None:
        resolved_level = resolve_anc_level(level)
        if resolved_level is None:
            log.error(
                f"Invalid ANC level. Valid: "
                f"{', '.join(NC_LEVELS.values())} "
                "(0-3)"
            )
            return None
        return self.set_anc_state_extended(NC_MODE_ON, resolved_level)

    def set_noise_control_setting(
        self, mode: int | None, value: int | None = None
    ) -> dict | None:
        requested = {
            side: cycle
            for side, cycle in (("left", mode), ("right", value))
            if cycle is not None
        }
        if not requested or any(
            type(cycle) is not int for cycle in requested.values()
        ):
            return None
        state = self.get_noise_control_setting() or {}
        if any(
            side not in state
            or cycle not in NOISE_CYCLES
            or cycle not in state.get("supported", ())
            for side, cycle in requested.items()
        ):
            return None
        frames = self.send_command(Cmd.set_noise_control(mode, value))
        reply = self._match_frame(frames, 0x2B, 0x18)
        if reply:
            status = self._parse_status_code(reply["data"])
            if status is not None and status != 100000:
                return {"success": False, "status": status}
        observed = self.get_noise_control_setting() or {}
        return {
            **requested,
            "success": all(observed.get(k) == v for k, v in requested.items()),
        }

    def set_noise_mode(self, mode: int) -> dict | None:
        return self.set_anc_state_extended(
            mode, 0 if mode == NC_MODE_OFF else 255
        )

    def get_sound_effect(self) -> dict | None:
        frames = self.send_command(Cmd.GET_EQ)
        f = self._match_frame(frames, 0x2B, 0x4A)
        if not f:
            log.warning("No sound effect response")
            return None
        data = f["data"]
        result = {"raw": data.hex(), "source": "eq_query"}
        status = self._parse_status_code(data)
        if status is not None:
            result["status"] = status
            result["status_ok"] = status in (0, 100000)
            if result["status_ok"]:
                log.debug("Sound effect: status OK")
            else:
                log.debug(f"Sound effect: status=0x{status:08X}")
            return result
        for tlv in parse_tlv(data):
            v = tlv["value"]
            if tlv["tag"] == 1 and len(v) == 1:
                result["support"] = v[0] == 1
            elif tlv["tag"] == 2 and len(v) == 1:
                result["mode"] = v[0]
                result["mode_name"] = EQ_MODES.get(v[0], f"Unknown ({v[0]})")
            elif tlv["tag"] == 3:
                modes = [b for b in v if b != 0xFF]
                result["modes"] = modes
                result["mode_names"] = [
                    EQ_MODES.get(m, f"Unknown ({m})") for m in modes
                ]
            elif tlv["tag"] == 4 and len(v) == 1:
                result["recommended"] = v[0]
            elif tlv["tag"] == 8:
                result["custom_data"] = v.hex()
        if "mode" in result:
            log.debug(f"Sound effect: {result['mode_name']}")
        return result

    def set_sound_effect(self, mode) -> dict | None:
        mode = resolve_eq_mode(mode)
        if mode is None:
            log.error(
                f"Invalid sound effect. Valid: {', '.join(EQ_MODES.values())} "
                "(1|2|3|9)"
            )
            return None
        state = self.get_sound_effect() or {}
        if "modes" in state and mode not in state["modes"]:
            return {"success": False, "error": "EQ preset was not advertised"}
        frames = self.send_command(Cmd.set_eq(mode))
        f = self._match_frame(frames, 0x2B, 0x49)
        if not f:
            log.warning("No sound effect set response")
            return None
        data = f["data"]
        result = {"mode": mode, "mode_name": EQ_MODES[mode]}

        status = self._parse_status_code(data)
        if status is not None:
            ok = status in (0, 100000)
            result["success"] = ok
            result["status"] = status
            if ok:
                log.debug(f"Sound effect: set to {EQ_MODES[mode]}")
            else:
                log.warning(
                    f"Sound effect: set failed (status=0x{status:08X})"
                )
            return result

        result["success"] = None
        log.warning(
            f"Sound effect: unrecognized set response (resp={data.hex()})"
        )
        return result

    def get_language_setting(self) -> dict | None:
        result = {}
        for command in (Cmd.GET_LANGUAGE, Cmd.GET_LANGUAGE_WITH_UNIT):
            frames = self.send_command(command)
            frame = self._match_frame(frames, 0x0C, 0x02)
            if frame is None:
                continue
            for tlv in parse_tlv(frame["data"]):
                tag, raw = tlv["tag"], tlv["value"]
                value = (
                    raw.decode("utf-8", errors="ignore").split("\x00", 1)[0].strip()
                )
                if tag == 1 and value:
                    result["current"] = value
                elif tag == 2 and len(raw) == 1:
                    result["unit"] = raw[0]
                elif tag == 3 and value:
                    result["tag3"] = value
                    result["supported"] = [
                        code.strip() for code in value.split(",") if code.strip()
                    ]
                elif value:
                    result[f"tag{tag}"] = value
            if result.get("current") and result.get("supported"):
                break

        if not result.get("current"):
            frame = self._match_frame(
                self.send_command(Cmd.GET_PROMPT_LANGUAGE_PACK), 0x2B, 0x51
            )
            name = self._extract_tlv_value(frame["data"], 1) if frame else None
            if name:
                pack = name.decode("utf-8", errors="ignore").rstrip("\x00").strip()
                pack = pack.lower().replace("_", "-")
                matches = []
                for code in result.get("supported", []):
                    locale = code.lower().replace("_", "-")
                    if locale == pack or (
                        "-" in locale
                        and re.search(
                            rf"(?:^|[^a-z0-9]){re.escape(locale)}(?:$|[^a-z0-9])",
                            pack,
                        )
                    ):
                        matches.append(code)
                if len(matches) == 1:
                    result["current"] = matches[0]
                if not result.get("current") and re.fullmatch(r"[a-z]{2,3}-[a-z]{2}", pack):
                    result["current"] = pack

        if not result:
            log.warning("No language setting response")
            return None
        log.debug(f"Language setting: {result}")
        return result

    def set_language(self, lang_str: str) -> dict | None:
        supported = (self.get_language_setting() or {}).get("supported")
        if supported and lang_str not in supported:
            return {
                "success": False,
                "error": "Unsupported prompt language",
                "supported": supported,
            }

        frames = self.send_command(Cmd.set_language(lang_str))
        f = self._match_frame(frames, 0x0C, 0x01)
        if not f:
            log.warning("No language set response")
            return None

        data = f["data"]
        result: dict[str, object] = {"language": lang_str}
        if supported:
            result["supported"] = supported

        status = self._parse_status_code(data)
        if status is not None:
            result["success"] = status == 100000
            result["status"] = status
            if result["success"]:
                log.debug(f"Language set: {lang_str}")
                if supported and lang_str not in supported:
                    log.warning(
                        f"Device said OK but '{lang_str}' "
                        "not in supported list "
                        f"{supported}"
                    )
            else:
                log.warning(
                    f"Language set failed: status=0x{status:08X} ({status})"
                )
        else:
            result["success"] = None
            log.debug(f"Language set unconfirmed: {data.hex()}")

        return result

    def get_cloud_version(self) -> dict | None:
        frames = self.send_command(Cmd.CLOUD_VERSION)
        f = self._match_frame(frames, 0x09, 0x08)
        if not f:
            log.warning("No cloud version response")
            return None
        result = {"data": f["data"].hex()}
        log.info(f"Cloud version response: {result['data']}")
        return result

    def get_ota_params(self) -> dict | None:
        frames = self.send_command(Cmd.GET_OTA_PARAMS)
        f = self._match_frame(frames, 0x09, 0x02)
        if not f:
            log.warning("No OTA params response")
            return None
        result = {"data": f["data"].hex()}
        log.info(f"OTA params response: {result['data']}")
        return result

    def _try_command(
        self, cmd: bytes, label: str = "", read_timeout: float = 0.5
    ) -> dict | None:
        frames = self.send_command(cmd, read_timeout=read_timeout)
        if not frames:
            return None
        for f in frames:
            if f.get("data"):
                return {
                    "label": label,
                    "cmd": cmd.hex(),
                    "response": f["data"].hex(),
                }
        return {"label": label, "cmd": cmd.hex(), "response": "ack_only"}

    def discover_anc(self, timeout: float = 0.3) -> list:
        results = []
        total = 0
        for svc in [0x01, 0x2B, 0x2C, 0x1B, 0x0B, 0x0D, 0x1C, 0x2D]:
            cmd_max = 40 if svc in (0x01, 0x2B) else 16
            for cmd in range(cmd_max):
                if svc == 0x2B and cmd in (
                    14,
                    15,
                    16,
                    17,
                    22,
                    23,
                    28,
                    29,
                    30,
                    31,
                    32,
                    33,
                    34,
                    35,
                ):
                    continue
                if svc == 0x01 and cmd in (
                    1,
                    2,
                    3,
                    7,
                    8,
                    13,
                    17,
                    19,
                    29,
                    31,
                    32,
                ):
                    continue
                total += 1
                payload = bytes([svc, cmd, 0x01, 0x00])
                r = self._try_command(
                    payload,
                    f"GET svc={svc:02X} cmd={cmd:02X}",
                    read_timeout=timeout,
                )
                if r:
                    results.append(r)
                    log.info(
                        f"Response on svc={svc:02X} cmd={cmd:02X}: "
                        f"{r['response']}"
                    )
        for label, probe_cmd in [
            ("ServiceAbility", Cmd.GET_SERVICE_ABILITY),
            ("CommandAbility", Cmd.GET_COMMAND_ABILITY),
        ]:
            r = self._try_command(probe_cmd, label, read_timeout=timeout)
            if r:
                results.append(r)
        log.info(f"Scan complete: {total} probes, {len(results)} responses")
        return results

    def get_all_info(self) -> dict:
        info: dict[str, Any] = {}
        info["battery"] = self.get_battery()
        info["version"] = self.get_version()
        info["noise_control"] = self.get_noise_control_status()
        info.update(info["noise_control"]["details"])
        info["noise_cycle"] = self.get_noise_control_setting()
        info["anc"] = self.get_noise_mode()
        info["sound_effect"] = self.get_sound_effect()
        info["language"] = self.get_language_setting()
        for fkey in FEATURES:
            info[fkey] = self.get_feature(fkey)
        return info


def scan_freebuds(scan_time: int = 10) -> list[dict]:
    found = []

    try:
        import asyncio

        from bleak import BleakScanner

        log.debug(f"BLE scanning {scan_time}s...")

        def cb(device, adv):
            name = adv.local_name or device.name or ""
            if "orange" in name.lower() or "freebuds" in name.lower():
                log.info(f"  BLE: {name} [{device.address}]")
                entry = {
                    "name": name,
                    "address": device.address,
                    "rssi": adv.rssi,
                }
                if entry not in found:
                    found.append(entry)

        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        scanner = BleakScanner(cb)
        loop.run_until_complete(scanner.start())
        loop.run_until_complete(asyncio.sleep(scan_time))
        loop.run_until_complete(scanner.stop())
        loop.close()
    except ImportError:
        pass
    except Exception as e:
        log.debug(f"BLE error: {e}")

    try:
        subprocess.run(
            ["bluetoothctl", "--timeout", str(scan_time), "scan", "on"],
            capture_output=True,
            check=False,
            timeout=scan_time + 5,
        )
        result = subprocess.run(
            ["bluetoothctl", "devices"],
            capture_output=True,
            check=False,
            text=True,
            timeout=5,
        )
        for line in result.stdout.strip().split("\n"):
            if "Device" in line:
                parts = line.split(" ", 2)
                if len(parts) >= 3:
                    addr, name = parts[1], parts[2]
                    if name and (
                        "FreeBuds" in name
                        or "freebuds" in name.lower()
                        or "Orange" == name
                    ):
                        log.debug(f"  BT: {name} [{addr}]")
                        entry = {"name": name, "address": addr}
                        if entry not in found:
                            found.append(entry)
    except Exception as e:
        log.debug(f"BT error: {e}")

    return found


def is_paired(address: str) -> bool:
    try:
        r = subprocess.run(
            ["bluetoothctl", "info", address],
            capture_output=True,
            check=False,
            text=True,
            timeout=5,
        )
        return "Paired: yes" in r.stdout
    except Exception:
        return False


COLOR_BORDER = "\033[38;2;120;81;255m"
COLOR_TITLE = "\033[38;2;254;202;87m"
COLOR_LABEL = "\033[38;2;162;171;206m"
COLOR_VAL = "\033[38;2;240;240;245m"
COLOR_ON = "\033[38;2;46;204;113m"
COLOR_OFF = "\033[38;2;231;76;60m"
COLOR_UNKNOWN = "\033[38;2;127;140;141m"
COLOR_MSG = "\033[38;2;243;156;18m"
COLOR_MENU_NUM = "\033[38;2;52;152;219m"
RESET = "\033[0m"
BOLD = "\033[1m"

ANC_MODES = {
    0: "Normal (Off)",
    1: "ANC On",
    2: "Transparency",
    3: "Wind Noise (KANG_FENG)",
    4: "Adaptive Auto-ANC",
}

STANDARD_EQ_PRESETS = {
    0: "Default",
    1: "Vocal",
    2: "Rock",
    3: "Classical",
    4: "Popularity",
    5: "Bass",
    6: "Subwoofer",
    7: "Soft",
    8: "Outdoor",
    240: "Custom/Customize",
}

S40_EQ_PRESETS = {
    0: "Default",
    1: "Subwoofer",
    2: "Rock",
    3: "Soft",
    4: "Classical",
    5: "Bass",
    6: "Subwoofer",
    7: "Soft",
    8: "Custom/Customize",
    15: "Custom/Customize",
    240: "Custom/Customize",
}

S40_EQ_WRITE_MAP = {
    0: 0,
    1: 6,
    2: 2,
    3: 7,
    4: 3,
}

LEGACY_GESTURE_TYPES = {1: "Double Tap", 2: "Triple Tap", 3: "Long Press"}

GESTURE_FUNCTIONS = {
    0: "Voice Assistant",
    1: "Play / Pause",
    2: "Previous Track",
    3: "Next Track",
    4: "Volume Up",
    5: "Volume Down",
    6: "ANC Toggle",
    7: "Game Mode",
    255: "Disabled / None",
}


class DeviceModel:
    def __init__(
        self,
        key,
        pid,
        name,
        form_factor="tws",
        has_anc=True,
        has_anc_levels=True,
        has_spatial_audio=False,
        has_ldac=False,
        has_tws_battery=True,
        has_gestures=True,
        has_wear_detection=False,
        has_auto_shutdown=True,
        has_anti_leak=False,
        eq_type="standard",
    ):
        self.key = key
        self.pid = pid
        self.name = name
        self.form_factor = form_factor
        self.has_anc = has_anc
        self.has_anc_levels = has_anc_levels
        self.has_spatial_audio = has_spatial_audio
        self.has_ldac = has_ldac
        self.has_tws_battery = has_tws_battery
        self.has_gestures = has_gestures
        self.has_wear_detection = has_wear_detection
        self.has_auto_shutdown = has_auto_shutdown
        self.has_anti_leak = has_anti_leak
        self.eq_type = eq_type

    def to_dict(self):
        return {
            "key": self.key,
            "pid": self.pid,
            "name": self.name,
            "form_factor": self.form_factor,
            "capabilities": {
                "has_anc": self.has_anc,
                "has_anc_levels": self.has_anc_levels,
                "has_spatial_audio": self.has_spatial_audio,
                "has_ldac": self.has_ldac,
                "has_tws_battery": self.has_tws_battery,
                "has_gestures": self.has_gestures,
                "has_wear_detection": self.has_wear_detection,
                "has_auto_shutdown": self.has_auto_shutdown,
                "has_anti_leak": self.has_anti_leak,
                "eq_type": self.eq_type,
            },
        }


class AiraController(FreeBudsController):
    """The app-facing device API, backed by the Huawei FreeBuds protocol."""

    def __init__(self, mac_address=None, channel=SPP_CHANNEL):
        super().__init__(mac_address)
        self.channel = channel
        self._adaptive_anc = None
        self.device_name = "Huawei FreeBuds 5i"
        self.model = DeviceModel(
            "FREEBUDS_5I",
            1,
            "Huawei FreeBuds 5i",
            form_factor="tws",
            has_anc=True,
            has_anc_levels=True,
            has_gestures=True,
            has_wear_detection=True,
            has_auto_shutdown=True,
        )

    def connect(self, mac_address=None, channel=None):
        self._adaptive_anc = None
        return super().connect(
            mac_address or self.mac_address, channel or self.channel
        )

    _extra_features = {
        "venh": ("get_voice_enhance", "set_voice_enhance"),
        "hd": ("get_hd_switch", "set_hd_switch"),
        "silent": ("get_silent_upgrade", "set_silent_upgrade"),
        "health": ("get_health_alerts", "set_health_alerts"),
        "greet": ("get_greet_setting", "set_greet"),
        "saving": ("get_saving_mode", "set_saving_mode"),
        "volume": ("get_intellect_volume", "set_intellect_volume"),
        "translate": ("get_translate_mode", "set_translate_mode"),
        "hd_voice": ("get_32k_hd", "set_32k_hd"),
        "ear_balance": ("get_left_right_ear", "set_left_right_ear"),
    }

    @staticmethod
    def _confirmed(result):
        if not result or result.get("success") is not True:
            raise ValueError(
                (result or {}).get("error")
                or "The earbuds did not confirm the change"
            )
        return result

    def app_freebuds_command(self, operation, args):
        if not self._connected:
            raise ValueError("FreeBuds disconnected")
        if operation == "controls":
            section = args["section"]
            if section == "gestures":
                return {
                    "gestures": {
                        key: self.get_gesture_action(key)
                        for key in GESTURE_TYPES
                    },
                    "cycle": self.get_noise_control_setting(),
                }
            if section == "wear":
                wear = self.get_wearing_status() or {}
                return {
                    side + "_in": value == 1
                    for side in ("left", "right")
                    if (value := wear.get(side + "_ear")) in (0, 1)
                }
            if section == "locator":
                return {
                    "locator": {
                        side: self.locator(side) for side in ("left", "right")
                    }
                }
            if section != "preferences":
                raise ValueError("Unknown FreeBuds controls section")
            features = {}
            for key, (getter, _) in self._extra_features.items():
                value = (getattr(self, getter)() or {}).get("enabled")
                if type(value) is bool:
                    features[key] = value
            return {
                "features": features,
                "language": self.get_language_setting(),
            }
        if operation == "information":
            version = self.get_version() or {}
            keys = (
                "model",
                "firmware",
                "ota_package",
                "bluetooth_version",
                "serial",
                "bud_serials",
            )
            return {
                "version": {key: version[key] for key in keys if key in version},
                "dynamic": (self.get_dynamic_anc_support() or {}).get("supported"),
            }
        if operation == "devices":
            return {
                "devices": [
                    {
                        key: value
                        for key, value in entry.items()
                        if key != "byte_addr"
                    }
                    for entry in self.get_bonded_devices()
                ]
            }
        if operation == "fit":
            return self._confirmed(self.run_fit_test())
        if operation == "eq":
            return self._confirmed(self.set_sound_effect(args["mode"]))
        if operation == "gesture":
            key, side, action = args["key"], args["side"], args["action"]
            result = (
                self.set_call_gesture(key, action)
                if side == "call"
                else self.set_gesture_action(
                    key, {"global": 0, "left": 1, "right": 2}[side], action
                )
            )
            self._confirmed(result)
            return self.get_gesture_action(key) or {}
        if operation == "noiseCycle":
            side, cycle = args["side"], args["cycle"]
            self._confirmed(
                self.set_noise_control_setting(
                    cycle if side == "left" else None,
                    cycle if side == "right" else None,
                )
            )
            return self.get_noise_control_setting() or {}
        if operation == "locator":
            return self._confirmed(self.locator(args["side"], args["ring"]))
        if operation == "language":
            code = args["code"]
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,16}", code):
                raise ValueError("Invalid prompt language")
            self._confirmed(self.set_language(code))
            return {"current": code, **(self.get_language_setting() or {})}
        if operation == "feature":
            key = args["key"]
            enabled = args["enabled"]
            if type(enabled) is not bool:
                raise ValueError("Expected a boolean setting")
            getter, setter = self._extra_features[key]
            if "enabled" not in (getattr(self, getter)() or {}):
                raise ValueError("This option is unavailable on the earbuds")
            self._confirmed(getattr(self, setter)(enabled))
            actual = (getattr(self, getter)() or {}).get("enabled")
            if actual is not enabled:
                raise ValueError("The earbuds did not apply the change")
            return {"enabled": actual}
        if operation == "device":
            action, mac = args["action"], args["mac"]
            if not any(
                device["addr"] == mac for device in self.get_bonded_devices()
            ):
                raise ValueError("Device is no longer paired with the earbuds")
            actions = {
                "connect": self.connect_device,
                "disconnect": self.disconnect_device,
                "primary": self.set_primary_device,
                "unpair": self.unpair_device,
            }
            result = (
                self.set_device_preference(mac, action, args["enabled"])
                if action in ("reconnect", "audio-switch")
                else actions[action](mac)
            )
            self._confirmed(result)
            return self.app_freebuds_command("devices", {})
        raise ValueError("Unknown FreeBuds operation")

    def get_status(self):
        with self._lock:
            version = self.get_version() or {}
            battery = self.get_battery() or {}
            noise = self.get_noise_mode() or {}
            eq = self.get_sound_effect() or {}
            dormant = self.get_dormant_time() or {}
            if self._adaptive_anc is None:
                self._adaptive_anc = (self.get_dynamic_anc_support() or {}).get("supported", False)

        status: dict[str, object] = {}
        submodel = version.get("sub_model_id")
        ota = (version.get("ota_package") or "").upper()
        model = (version.get("model") or "").upper()
        is_5i = (
            submodel in ("01", "07", "0C")
            or "BTFT0014" in ota
            or "00013D" in ota
            or "T0012" in model
        )
        friendly = "Huawei FreeBuds 5i" if is_5i else "Huawei FreeBuds"
        self.device_name = self.custom_name or friendly
        status["device_name"] = self.device_name
        model_info = self.model.to_dict()
        if submodel:
            model_info["sub_model_id"] = submodel
        model_info["adaptive_anc"] = self._adaptive_anc or noise.get("level") == NC_LEVEL_DYNAMIC
        if "modes" in eq:
            model_info["eq_modes"] = eq["modes"]
        if eq.get("support") is False:
            model_info["eq_modes"] = []
        status["model_info"] = model_info

        def pct(key):
            value = battery.get(key)
            return f"{value}%" if isinstance(value, int) else None

        left, right, case = (
            pct("left_battery"),
            pct("right_battery"),
            pct("box_battery"),
        )
        (
            status["battery_left"],
            status["battery_right"],
            status["battery_case"],
        ) = left, right, case
        status["battery"] = (
            f"L: {left} | R: {right}" if left and right else "Unknown"
        )

        mode, level = noise.get("mode"), noise.get("level")
        if mode == NC_MODE_OFF:
            status["anc_mode"] = "Normal (Off)"
        elif mode == NC_MODE_AWARE:
            status["anc_mode"] = "Transparency"
        elif level == NC_LEVEL_DYNAMIC:
            status["anc_mode"] = "Adaptive Auto-ANC"
        elif mode == NC_MODE_ON:
            status["anc_mode"] = "ANC On"
        else:
            status["anc_mode"] = "Unknown"

        status["anc_level"] = {
            NC_LEVEL_ULTRA: "High",
            NC_LEVEL_GENERAL: "Medium",
            NC_LEVEL_COZY: "Low",
            NC_LEVEL_DYNAMIC: "Adaptive",
        }.get(level, "N/A")
        status["eq_mode"] = eq.get("mode_name") or EQ_MODES.get(
            eq.get("mode"), "Default"
        )

        def enabled(result):
            return "Enabled" if (result or {}).get("enabled") else "Disabled"

        with self._lock:
            status["game_mode"] = enabled(self.get_feature("glat"))
            status["wind_noise"] = enabled(self.get_feature("wind"))
            status["multipoint"] = enabled(self.get_feature("dual"))
            status["ldac"] = enabled(self.get_feature("hd"))
            status["wear_detection"] = enabled(self.get_feature("wear"))
            status["anti_leak"] = "N/A"
            status["spatial_audio"] = "N/A"
            status["spatial_scene"] = "N/A"

            seconds = dormant.get("value")
            status["auto_shutdown"] = (
                {
                    1800: "30 mins",
                    3600: "1 hour",
                    10800: "3 hours",
                    18000: "5 hours",
                    0: "Never",
                }.get(seconds, "Unknown")
                if isinstance(seconds, int)
                else "Unknown"
            )

            gestures = {}
            for app_key, gkey in (
                (1, "double_click"),
                (2, "triple_click"),
                (3, "long_press"),
            ):
                state = self.get_gesture_action(gkey) or {}
                entry = {}
                for side_name, side in (
                    ("left", SIDE_LEFT),
                    ("right", SIDE_RIGHT),
                ):
                    side_state = (
                        state.get(side_name)
                        if isinstance(state.get(side_name), dict)
                        else state
                    )
                    value = (side_state or {}).get(
                        "action", state.get("action")
                    )
                    if isinstance(value, int):
                        entry[f"{side_name}_func"] = value
                if entry:
                    gestures[str(app_key)] = entry
            status["gestures"] = gestures
        return status

    def set_anc_mode(self, mode):
        if mode == 4:
            result = self.set_anc_state_extended(NC_MODE_ON, NC_LEVEL_DYNAMIC)
        else:
            fb_mode = {
                0: NC_MODE_OFF,
                1: NC_MODE_ON,
                2: NC_MODE_AWARE,
                3: NC_MODE_AWARE,
            }.get(mode, NC_MODE_OFF)
            result = self.set_noise_mode(fb_mode)
        return bool(result and result.get("success"))

    def set_anc_level_fb(self, level):
        return self.set_anc_level(
            {0: NC_LEVEL_ULTRA, 1: NC_LEVEL_GENERAL, 2: NC_LEVEL_COZY}.get(
                level, NC_LEVEL_GENERAL
            )
        )

    def set_game_mode(self, enabled):
        return self.set_feature("glat", bool(enabled)) is not None

    def set_wind_noise(self, enabled):
        return self.set_feature("wind", bool(enabled)) is not None

    def set_multipoint(self, enabled):
        return self.set_feature("dual", bool(enabled)) is not None

    def set_ldac(self, enabled):
        return self.set_feature("hd", bool(enabled)) is not None

    def set_wear_detection(self, enabled):
        return self.set_wear(bool(enabled)) is not None

    def set_anti_leak(self, enabled):
        log.info("Anti-sound-leak is not available on FreeBuds")
        return True

    def set_auto_play(self, enabled):
        log.info("Auto-play is not available on FreeBuds")
        return True

    def set_auto_shutdown(self, timer_val):
        seconds = {1: 1800, 2: 3600, 6: 10800, 10: 18000, 255: 0}.get(
            timer_val, 0
        )
        return self.set_dormant_time(0, seconds) is not None

    def set_spatial_audio(self, mode):
        log.info("Spatial audio is not available on FreeBuds")
        return True

    def set_spatial_scene(self, scene_idx):
        log.info("Spatial audio scene is not available on FreeBuds")
        return True

    def set_eq_preset(self, preset_idx):
        result = self.set_sound_effect(
            {0: EQ_MODE_DEFAULT, 5: EQ_MODE_BASS, 9: EQ_MODE_VOICES}.get(
                preset_idx, EQ_MODE_DEFAULT
            )
        )
        return bool(result and result.get("success"))

    def set_custom_eq(self, gains):
        log.info(
            "Custom graphic EQ is not available on FreeBuds; "
            "using default sound effect"
        )
        return self.set_sound_effect(EQ_MODE_DEFAULT) is not None

    def set_gesture(self, gesture_type, left_func, right_func):
        gesture = {1: "double_click", 2: "triple_click", 3: "long_press"}.get(
            gesture_type, "double_click"
        )
        actions = {0: 0, 1: 1, 2: 7, 3: 2, 255: 255}
        ok = True
        for side, func in ((SIDE_LEFT, left_func), (SIDE_RIGHT, right_func)):
            ok = (
                self.set_gesture_action(
                    gesture, side, actions.get(int(func), 255)
                )
                is not None
                and ok
            )
        return ok

    def set_device_name(self, name):
        self.custom_name = name or None
        return True

    def find_device(self, is_play=True, earbud_id=3):
        results = [self.locator(side, ring=bool(is_play)) for side in ("left", "right")]
        return all(result and result.get("success") is True for result in results)


FREEBUDS_NAME_REGEX = re.compile(
    r"(huawei|freebuds|freebud|flypods|orange)", re.IGNORECASE
)


def scan_paired_devices():
    try:
        return [(d["address"], d["name"]) for d in scan_freebuds(scan_time=5)]
    except Exception as e:
        print(f"Error scanning devices: {e}")
        return []


def find_control_port(mac_address):
    return SPP_CHANNEL


def clean_ansi(s):
    return re.sub(r"\033\[[0-9;]*m", "", s)


def draw_top_border(width=58):
    print(f"{COLOR_BORDER}┌{'─' * (width - 2)}┐{RESET}")


def draw_bottom_border(width=58):
    print(f"{COLOR_BORDER}└{'─' * (width - 2)}┘{RESET}")


def draw_separator(width=58):
    print(f"{COLOR_BORDER}├{'─' * (width - 2)}┤{RESET}")


def draw_centered_line(text, width=58):
    visible_text = clean_ansi(text)
    padding_total = width - len(visible_text) - 2
    pad_left = padding_total // 2
    pad_right = padding_total - pad_left
    print(
        f"{COLOR_BORDER}│{RESET}{' ' * pad_left}{text}"
        f"{' ' * pad_right}{COLOR_BORDER}│{RESET}"
    )


def draw_line(label, value_str, width=58):
    left_str = f"  {COLOR_LABEL}{label:<16}{RESET} : {value_str}"
    visible_left = clean_ansi(left_str)
    spaces_needed = width - len(visible_left) - 2
    print(
        f"{COLOR_BORDER}│{RESET}{left_str}"
        f"{' ' * spaces_needed}{COLOR_BORDER}│{RESET}"
    )


def draw_dashboard(status, msg=""):
    print("\033[H\033[2J", end="")

    model_info = status.get("model_info", {})
    model_name = model_info.get("name", "HAYLOU DEVICE").upper()
    caps = model_info.get("capabilities", {})

    draw_top_border()
    draw_centered_line(f"{BOLD}{COLOR_TITLE}{model_name} CONTROL{RESET}")
    draw_separator()

    dev_name = status.get("device_name", "Unknown")
    draw_line("Device Name", f"{COLOR_VAL}{dev_name}{RESET}")

    b_left = status.get("battery_left")
    b_right = status.get("battery_right")
    b_case = status.get("battery_case")
    if b_left is not None and b_right is not None:
        case_txt = f" | Case: {b_case}" if b_case else ""
        draw_line(
            "TWS Battery",
            f"{COLOR_ON}L: {b_left} | R: {b_right}{case_txt}{RESET}",
        )
    else:
        battery_str = status.get("battery", "Unknown")
        if battery_str != "Unknown" and "%" in battery_str:
            try:
                pct = int(battery_str.replace("%", "").strip())
                bar_len = pct // 10
                bar = "█" * bar_len + "░" * (10 - bar_len)
                lvl_color = (
                    COLOR_ON
                    if pct > 50
                    else (COLOR_TITLE if pct > 20 else COLOR_OFF)
                )
                battery_display = f"{lvl_color}[{bar}] {pct}%{RESET}"
            except ValueError:
                battery_display = f"{COLOR_UNKNOWN}{battery_str}{RESET}"
        else:
            battery_display = f"{COLOR_UNKNOWN}Unknown{RESET}"
        draw_line("Battery State", battery_display)

    wear_state = status.get("wear_state", "Unknown")
    wear_color = (
        COLOR_ON
        if wear_state == "Worn"
        else (COLOR_TITLE if wear_state == "Off-Ear" else COLOR_UNKNOWN)
    )
    draw_line("Wear State", f"{wear_color}{wear_state}{RESET}")
    draw_separator()

    if caps.get("has_anc", True):
        anc = status.get("anc_mode", "Unknown")
        anc_colors = {
            "Normal (Off)": COLOR_VAL,
            "ANC On": COLOR_ON,
            "Transparency": COLOR_MENU_NUM,
            "Wind Noise (KANG_FENG)": COLOR_TITLE,
            "Adaptive Auto-ANC": "\033[38;2;155;89;182m",
        }
        anc_col = anc_colors.get(anc, COLOR_UNKNOWN)
        draw_line("ANC Mode", f"{anc_col}{anc}{RESET}")

        if caps.get("has_anc_levels", True) and anc in [
            "ANC On",
            "Adaptive Auto-ANC",
        ]:
            anc_lvl = status.get("anc_level", "Unknown")
            draw_line("ANC Level", f"{COLOR_VAL}{anc_lvl}{RESET}")

    eq = status.get("eq_mode", "Unknown")
    draw_line("EQ Preset", f"{COLOR_VAL}{eq}{RESET}")

    def get_toggle_display(key):
        val = status.get(key, "Unknown")
        if val == "Enabled":
            return f"{COLOR_ON}[ ENABLED ]{RESET}"
        elif val == "Disabled":
            return f"{COLOR_OFF}[ DISABLED ]{RESET}"
        elif val == "N/A":
            return f"{COLOR_UNKNOWN}[ N/A ]{RESET}"
        return f"{COLOR_UNKNOWN}[ UNKNOWN ]{RESET}"

    draw_line("Game Mode", get_toggle_display("game_mode"))
    draw_line("Wind Noise Red.", get_toggle_display("wind_noise"))
    draw_line("Multipoint", get_toggle_display("multipoint"))

    if caps.get("has_ldac", False):
        draw_line("LDAC Support", get_toggle_display("ldac"))

    if caps.get("has_wear_detection", False):
        draw_line("Wear Detection", get_toggle_display("wear_detection"))

    if caps.get("has_anti_leak", False):
        draw_line("Anti-Sound Leak", get_toggle_display("anti_leak"))

    if caps.get("has_spatial_audio", False):
        spatial_val = status.get("spatial_audio", "Off")
        if spatial_val == "Off":
            spatial_display = f"{COLOR_OFF}[ OFF ]{RESET}"
        elif spatial_val in ("Static", "Dynamic"):
            spatial_display = f"{COLOR_ON}[ {spatial_val.upper()} ]{RESET}"
        else:
            spatial_display = f"{COLOR_UNKNOWN}[ {spatial_val} ]{RESET}"
        draw_line("Spatial Audio", spatial_display)

        if spatial_val != "Off":
            scene_str = status.get("spatial_scene", "Unknown")
            draw_line("Spatial Scene", f"{COLOR_VAL}{scene_str}{RESET}")

    if caps.get("has_auto_shutdown", True):
        shutdown_str = status.get("auto_shutdown", "Unknown")
        draw_line("Auto-Shutdown", f"{COLOR_VAL}{shutdown_str}{RESET}")

    gestures = status.get("gestures", {})
    if gestures:
        draw_separator()
        draw_centered_line(f"{BOLD}Touch Gestures{RESET}")
        for g_id, g_info in gestures.items():
            t_name = g_info.get("type_name", f"Type {g_id}")
            l_fn = g_info.get("left_name", "N/A")
            r_fn = g_info.get("right_name", "N/A")
            draw_line(t_name[:16], f"{COLOR_VAL}L: {l_fn} | R: {r_fn}{RESET}")

    draw_bottom_border()

    if msg:
        print(f"\n{COLOR_MSG}» Message: {msg}{RESET}\n")
    else:
        print()


def print_menu(model):
    def print_col(left_num, left_text, right_num, right_text):
        left_str = f"  {COLOR_MENU_NUM}[{left_num:>2}]{RESET} {left_text}"
        visible_left = f"  [{left_num:>2}] {left_text}"
        spaces = 32 - len(visible_left)
        right_str = f"{COLOR_MENU_NUM}[{right_num:>2}]{RESET} {right_text}"
        print(f"{left_str}{' ' * spaces}{right_str}")

    print_col("1", "Set ANC Mode", "7", "Set EQ Preset")
    print_col(
        "2",
        "Toggle Game Mode",
        "8",
        "Toggle Spatial Audio" if model.has_spatial_audio else "Set Gestures",
    )
    print_col(
        "3",
        "Toggle Wind Noise",
        "9",
        "Set Spatial Audio Scene"
        if model.has_spatial_audio
        else "Toggle Anti-Leak",
    )
    print_col("4", "Toggle Multipoint", "10", "Set Auto-Shutdown Timer")
    print_col(
        "5",
        "Toggle LDAC (Reboot)" if model.has_ldac else "Toggle Auto-Play",
        "11",
        "Rename Device",
    )
    print_col("6", "Toggle Wear Detection", "12", "Find My Device (Ring)")
    print(f"{' ' * 4} [13] Refresh Status {' ' * 8} [0] Disconnect & Exit")


def interactive_menu(controller):
    msg = ""
    while True:
        try:
            status = controller.get_status()
            draw_dashboard(status, msg)
            msg = ""
        except (OSError, RuntimeError) as e:
            print(
                f"\n{COLOR_OFF}Connection lost ({e}). Reconnecting...{RESET}"
            )
            controller.disconnect()
            reconnected = False
            while not reconnected:
                try:
                    time.sleep(3.0)
                    reconnected = controller.connect()
                except (KeyboardInterrupt, SystemExit):
                    print("\nExiting.")
                    sys.exit(0)
                except Exception:
                    pass
            msg = "Connection re-established."
            continue

        model = controller.model
        print_menu(model)

        try:
            choice = input(f"\n{BOLD}Select option [0-13]:{RESET} ").strip()
        except (KeyboardInterrupt, EOFError):
            print()
            break

        if choice == "0":
            break
        elif choice == "1":
            if not model.has_anc:
                msg = "ANC is not supported on this model."
                continue
            print("\nSelect ANC Mode:")
            print(" 0. Normal (Off)")
            print(" 1. ANC On")
            print(" 2. Transparency")
            print(" 4. Adaptive ANC (Auto)")
            try:
                mode_choice = input("Select ANC mode [0, 1, 2, 4]: ").strip()
            except (KeyboardInterrupt, EOFError):
                print()
                continue
            if mode_choice in ["0", "1", "2", "4"]:
                m = int(mode_choice)
                success = controller.set_anc_mode(m)
                msg = (
                    "ANC mode updated."
                    if success
                    else "Failed to update ANC mode."
                )
            else:
                msg = "Invalid ANC mode choice."
        elif choice == "2":
            current = status.get("game_mode", "Disabled")
            enable = current != "Enabled"
            success = controller.set_game_mode(enable)
            msg = (
                f"Game Mode {'enabled' if enable else 'disabled'}."
                if success
                else "Failed to update Game Mode."
            )
        elif choice == "3":
            current = status.get("wind_noise", "Disabled")
            enable = current != "Enabled"
            success = controller.set_wind_noise(enable)
            msg = (
                f"Wind Noise Reduction {'enabled' if enable else 'disabled'}."
                if success
                else "Failed to update Wind Noise."
            )
        elif choice == "4":
            current = status.get("multipoint", "Disabled")
            enable = current != "Enabled"
            success = controller.set_multipoint(enable)
            msg = (
                f"Multipoint {'enabled' if enable else 'disabled'}."
                if success
                else "Failed to update Multipoint."
            )
        elif choice == "5":
            if model.has_ldac:
                current = status.get("ldac", "Disabled")
                enable = current != "Enabled"
                print(f"\nToggling LDAC to {'ON' if enable else 'OFF'}...")
                print("Headphones will reboot to apply this setting.")
                success = controller.set_ldac(enable)
                if success:
                    print("Setting accepted. Headphones are rebooting...")
                    controller.disconnect()
                    time.sleep(1.0)
                    reconnected = False
                    while not reconnected:
                        try:
                            time.sleep(3.0)
                            reconnected = controller.connect()
                        except (KeyboardInterrupt, SystemExit):
                            print("\nExiting.")
                            sys.exit(0)
                        except Exception:
                            pass
                    "Reconnected! LDAC is now "
                    f"{'Enabled' if enable else 'Disabled'}."
                else:
                    msg = "Failed to toggle LDAC."
            else:
                current = status.get("auto_play", "Disabled")
                enable = current != "Enabled"
                success = controller.set_auto_play(enable)
                msg = (
                    f"In-Ear Auto Play {'enabled' if enable else 'disabled'}."
                    if success
                    else "Failed to update Auto-Play."
                )
        elif choice == "6":
            if not model.has_wear_detection:
                msg = "Wear Detection is not supported on this model."
                continue
            current = status.get("wear_detection", "Disabled")
            enable = current != "Enabled"
            success = controller.set_wear_detection(enable)
            msg = (
                f"Wear Detection {'enabled' if enable else 'disabled'}."
                if success
                else "Failed to update Wear Detection."
            )
        elif choice == "7":
            presets_map = (
                S40_EQ_PRESETS
                if model.eq_type == "s40"
                else STANDARD_EQ_PRESETS
            )
            print(f"\nSelect EQ Preset ({model.name}):")
            if model.eq_type == "s40":
                print(
                    " 0. Default\n 1. Subwoofer\n 2. Rock\n"
                    " 3. Soft\n 4. Classical"
                )
                valid_opts = ["0", "1", "2", "3", "4"]
            else:
                for k in range(9):
                    print(f" {k}. {presets_map.get(k)}")
                valid_opts = [str(k) for k in range(9)]
            try:
                preset_choice = input(
                    f"Select preset [{valid_opts[0]}-{valid_opts[-1]}]: "
                ).strip()
            except (KeyboardInterrupt, EOFError):
                print()
                continue
            if preset_choice in valid_opts:
                idx = int(preset_choice)
                success = controller.set_eq_preset(idx)
                msg = (
                    f"EQ Preset set to {presets_map.get(idx, idx)}."
                    if success
                    else "Failed to set EQ Preset."
                )
            else:
                msg = "Invalid preset choice."
        elif choice == "8":
            if model.has_spatial_audio:
                print("\nSelect Spatial Audio Mode:")
                print(" 0. Off\n 1. Static\n 2. Dynamic")
                try:
                    spatial_choice = input("Select mode [0-2]: ").strip()
                except (KeyboardInterrupt, EOFError):
                    print()
                    continue
                if spatial_choice in ["0", "1", "2"]:
                    m = int(spatial_choice)
                    val_map = {0: 2, 1: 1, 2: 0}
                    success = controller.set_spatial_audio(val_map[m])
                    modes_desc = {0: "Off", 1: "Static", 2: "Dynamic"}
                    msg = (
                        f"Spatial Audio set to {modes_desc[m]}."
                        if success
                        else "Failed to set Spatial Audio."
                    )
                else:
                    msg = "Invalid Spatial Audio choice."
            elif model.has_gestures:
                print("\nSelect Touch Gesture to Configure:")
                print(" 1. Double Tap\n 2. Triple Tap\n 3. Long Press")
                try:
                    g_type_in = input("Select gesture [1-3]: ").strip()
                except (KeyboardInterrupt, EOFError):
                    print()
                    continue
                if g_type_in in ["1", "2", "3"]:
                    g_type = int(g_type_in)
                    print("\nAvailable Gesture Actions:")
                    for f_id, f_name in GESTURE_FUNCTIONS.items():
                        print(f" {f_id:>3}. {f_name}")
                    try:
                        l_fn_in = input("Select LEFT earbud action: ").strip()
                        r_fn_in = input("Select RIGHT earbud action: ").strip()
                        l_fn = int(l_fn_in)
                        r_fn = int(r_fn_in)
                        if (
                            l_fn in GESTURE_FUNCTIONS
                            and r_fn in GESTURE_FUNCTIONS
                        ):
                            success = controller.set_gesture(
                                g_type, l_fn, r_fn
                            )
                            msg = (
                                f"Updated {LEGACY_GESTURE_TYPES[g_type]} "
                                "gesture."
                                if success
                                else "Failed to update gesture."
                            )
                        else:
                            msg = "Invalid function code."
                    except (ValueError, KeyboardInterrupt, EOFError):
                        msg = "Invalid action input."
                else:
                    msg = "Invalid gesture type selection."
            else:
                msg = "Option not applicable to this model."
        elif choice == "9":
            if model.has_spatial_audio:
                print("\nSelect Spatial Audio Scene:")
                print(" 0. Music\n 1. Sport\n 2. Movie")
                try:
                    scene_choice = input("Select scene [0-2]: ").strip()
                except (KeyboardInterrupt, EOFError):
                    print()
                    continue
                if scene_choice in ["0", "1", "2"]:
                    idx = int(scene_choice)
                    success = controller.set_spatial_scene(idx)
                    scenes = {0: "Music", 1: "Sport", 2: "Movie"}
                    msg = (
                        f"Spatial Scene set to {scenes[idx]}."
                        if success
                        else "Failed to update Spatial Scene."
                    )
                else:
                    msg = "Invalid Spatial Scene choice."
            elif model.has_anti_leak:
                current = status.get("anti_leak", "Disabled")
                enable = current != "Enabled"
                success = controller.set_anti_leak(enable)
                msg = (
                    f"Anti-Sound Leak {'enabled' if enable else 'disabled'}."
                    if success
                    else "Failed to update Anti-Sound Leak."
                )
            else:
                msg = "Option not applicable to this model."
        elif choice == "10":
            if not model.has_auto_shutdown:
                msg = "Auto-Shutdown timer is not supported on this model."
                continue
            print("\nSelect Auto-Shutdown Timer Duration:")
            print(
                " 0. 30 Minutes\n 1. 1 Hour\n 2. 3 Hours\n"
                " 3. 5 Hours\n 4. Never (Disabled)"
            )
            try:
                timer_choice = input("Select duration [0-4]: ").strip()
            except (KeyboardInterrupt, EOFError):
                print()
                continue
            timer_map = {
                "0": (1, "30 minutes"),
                "1": (2, "1 hour"),
                "2": (6, "3 hours"),
                "3": (10, "5 hours"),
                "4": (255, "Never"),
            }
            if timer_choice in timer_map:
                byte_val, display_name = timer_map[timer_choice]
                success = controller.set_auto_shutdown(byte_val)
                msg = (
                    f"Auto-Shutdown set to {display_name}."
                    if success
                    else "Failed to update Auto-Shutdown."
                )
            else:
                msg = "Invalid timer selection."
        elif choice == "11":
            try:
                new_name = input("\nEnter new Bluetooth name: ").strip()
            except (KeyboardInterrupt, EOFError):
                print()
                continue
            if new_name:
                print(f"Renaming device to '{new_name}'...")
                success = controller.set_device_name(new_name)
                msg = (
                    f"Device renamed to '{new_name}'."
                    if success
                    else "Failed to rename device."
                )
            else:
                msg = "Device name cannot be empty."
        elif choice == "12":
            print("\nFind My Device:")
            print(" 1. Start Ringing\n 0. Stop Ringing")
            try:
                find_choice = input("Select action [0, 1]: ").strip()
            except (KeyboardInterrupt, EOFError):
                print()
                continue
            if find_choice in ["0", "1"]:
                play = find_choice == "1"
                success = controller.find_device(is_play=play)
                msg = (
                    f"Find device sound {'started' if play else 'stopped'}."
                    if success
                    else "Failed to send find device command."
                )
            else:
                msg = "Invalid find action."
        elif choice == "13":
            msg = "Status refreshed."
        else:
            msg = "Invalid option. Please choose [0-13]."

        time.sleep(0.5)


def json_mode_loop(controller):
    sock_lock = threading.Lock()
    cmd_queue = queue.Queue()

    def stdin_reader():
        while True:
            try:
                line = sys.stdin.readline()
                if not line:
                    break
                cmd_queue.put(line)
            except Exception:
                break
        cmd_queue.put(None)

    reader_thread = threading.Thread(target=stdin_reader, daemon=True)
    reader_thread.start()

    with sock_lock:
        try:
            status = controller.get_status()
            status["connection_status"] = "connected"
            _original_print(json.dumps(status), flush=True)
        except Exception as e:
            _original_print(
                json.dumps(
                    {"connection_status": "disconnected", "error": str(e)}
                ),
                flush=True,
            )
            return

    last_poll_time = time.time()

    while True:
        try:
            line = cmd_queue.get(timeout=1.0)
            if line is None:
                break

            try:
                cmd = json.loads(line)
                action = cmd.get("action") or cmd.get("command")
                value = cmd.get("value")

                if "request_id" in cmd:
                    reply = {"request_id": cmd["request_id"]}
                    try:
                        with sock_lock:
                            reply["result"] = controller.app_freebuds_command(
                                action, cmd.get("arguments", {})
                            )
                    except Exception as error:
                        reply["error"] = str(error)
                    _original_print(json.dumps(reply), flush=True)
                    if not controller._connected:
                        _original_print(
                            json.dumps({"connection_status": "disconnected"}),
                            flush=True,
                        )
                        return
                    continue

                success = False
                with sock_lock:
                    if action in ("set_anc", "set_anc_mode"):
                        success = controller.set_anc_mode(int(value))
                    elif action == "set_anc_level":
                        success = controller.set_anc_level_fb(int(value))
                    elif action == "set_game_mode":
                        success = controller.set_game_mode(bool(value))
                    elif action in (
                        "set_wind_noise",
                        "set_wind_noise_suppression",
                    ):
                        success = controller.set_wind_noise(bool(value))
                    elif action == "set_multipoint":
                        success = controller.set_multipoint(bool(value))
                    elif action == "set_ldac":
                        success = controller.set_ldac(bool(value))
                        if success:
                            controller.disconnect()
                    elif action == "set_wear_detection":
                        success = controller.set_wear_detection(bool(value))
                    elif action == "set_anti_leak":
                        success = controller.set_anti_leak(bool(value))
                    elif action == "set_auto_play":
                        success = controller.set_auto_play(bool(value))
                    elif action == "set_auto_shutdown":
                        success = controller.set_auto_shutdown(int(value))
                    elif action == "set_spatial_audio":
                        if isinstance(value, bool):
                            val_int = 1 if value else 2
                        else:
                            try:
                                val_int = int(value)
                            except ValueError:
                                val_str = str(value).lower()
                                if val_str == "dynamic":
                                    val_int = 0
                                elif val_str == "static":
                                    val_int = 1
                                else:
                                    val_int = 2
                        success = controller.set_spatial_audio(val_int)
                    elif action == "set_spatial_scene":
                        success = controller.set_spatial_scene(int(value))
                    elif action == "set_eq_preset":
                        success = controller.set_eq_preset(int(value))
                    elif action == "set_custom_eq":
                        gains = (
                            value
                            if isinstance(value, list)
                            else (
                                cmd.get("gains", [])
                                if isinstance(cmd, dict)
                                else []
                            )
                        )
                        success = controller.set_custom_eq(gains)
                    elif action == "set_gesture":
                        g_type = int(
                            cmd.get(
                                "gesture_type",
                                value if isinstance(value, int) else 1,
                            )
                        )
                        l_fn = int(cmd.get("left_func", cmd.get("left", 255)))
                        r_fn = int(
                            cmd.get("right_func", cmd.get("right", 255))
                        )
                        success = controller.set_gesture(g_type, l_fn, r_fn)
                    elif action == "get_gestures":
                        success = True
                    elif action == "find_device":
                        play = bool(value) if isinstance(value, bool) else True
                        earbud_id = (
                            int(cmd.get("earbud_id", 3))
                            if isinstance(cmd, dict)
                            else 3
                        )
                        success = controller.find_device(
                            is_play=play, earbud_id=earbud_id
                        )
                    elif action in ("rename", "rename_device"):
                        success = controller.set_device_name(str(value))
                    elif action in ("get_status", "refresh_status"):
                        success = True
                    elif action == "disconnect":
                        controller.disconnect()
                        _original_print(
                            json.dumps({"connection_status": "disconnected"}),
                            flush=True,
                        )
                        return

                with sock_lock:
                    try:
                        status = controller.get_status()
                        status["connection_status"] = (
                            "connected" if controller.sock else "disconnected"
                        )
                        status["command_success"] = success
                        status["last_action"] = action
                        _original_print(json.dumps(status), flush=True)
                    except Exception as e:
                        _original_print(
                            json.dumps(
                                {
                                    "connection_status": "disconnected",
                                    "error": str(e),
                                }
                            ),
                            flush=True,
                        )
                        break
            except Exception as e:
                _original_print(
                    json.dumps({"error": f"Failed to execute command: {e}"}),
                    flush=True,
                )

        except queue.Empty:
            pass

        if time.time() - last_poll_time >= 10.0:
            with sock_lock:
                try:
                    if controller.sock:
                        status = controller.get_status()
                        status["connection_status"] = "connected"
                        _original_print(json.dumps(status), flush=True)
                except Exception as e:
                    _original_print(
                        json.dumps(
                            {
                                "connection_status": "disconnected",
                                "error": str(e),
                            }
                        ),
                        flush=True,
                    )
                    break
            last_poll_time = time.time()


def _stop_daemon(_signal, _frame):
    raise SystemExit(0)


def main():
    global JSON_MODE
    parser = argparse.ArgumentParser(
        description="Aira — Huawei FreeBuds controller"
    )
    parser.add_argument(
        "-m",
        "--mac",
        help="MAC address of paired headphones (e.g. AA:BB:CC:DD:EE:FF)",
    )
    parser.add_argument(
        "-p",
        "--port",
        type=int,
        help="RFCOMM port/channel number (defaults to auto-detection)",
    )
    parser.add_argument(
        "-j",
        "--json",
        action="store_true",
        help="Enable JSON daemon mode for stdin/stdout communication",
    )
    args = parser.parse_args()

    mac = args.mac
    if args.json:
        JSON_MODE = True
        signal.signal(signal.SIGTERM, _stop_daemon)
        if not mac:
            devices = scan_paired_devices()
            if not devices:
                _original_print(
                    json.dumps({"connection_status": "no_devices"}), flush=True
                )
                sys.exit(0)
            mac, name = devices[0]
            _original_print(
                json.dumps(
                    {
                        "connection_status": "connecting",
                        "mac": mac,
                        "device_name": name,
                    }
                ),
                flush=True,
            )
        else:
            _original_print(
                json.dumps({"connection_status": "connecting", "mac": mac}),
                flush=True,
            )

        port = args.port
        if not port:
            port = find_control_port(mac)

        controller = AiraController(mac)
        if controller.connect():
            try:
                json_mode_loop(controller)
            finally:
                controller.disconnect()
        else:
            _original_print(
                json.dumps({"connection_status": "failed"}), flush=True
            )
            sys.exit(0)
    else:
        if not mac:
            devices = scan_paired_devices()
            if not devices:
                print("No paired Huawei FreeBuds detected.")
                mac = input(
                    "Please enter your headphone's MAC Address manually: "
                ).strip()
                if not mac:
                    print("Error: MAC address is required.")
                    sys.exit(1)
            elif len(devices) == 1:
                mac, name = devices[0]
                print(f"Found paired device: {name} ({mac})")
            else:
                print("\nPaired Huawei devices found:")
                for i, (d_mac, d_name) in enumerate(devices):
                    print(f" [{i + 1}] {d_name} ({d_mac})")
                choice = input(f"Select device [1-{len(devices)}]: ").strip()
                try:
                    idx = int(choice) - 1
                    if 0 <= idx < len(devices):
                        mac, name = devices[idx]
                    else:
                        print("Invalid selection.")
                        sys.exit(1)
                except ValueError:
                    print("Invalid input.")
                    sys.exit(1)

        port = args.port
        if not port:
            port = find_control_port(mac)

        controller = AiraController(mac)
        if controller.connect():
            try:
                interactive_menu(controller)
            finally:
                controller.disconnect()


if __name__ == "__main__":
    main()
