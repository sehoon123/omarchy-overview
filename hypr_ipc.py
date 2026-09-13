"""Bounded, local Hyprland IPC. Same wire format as hyprctl; no subprocesses."""
import json
import os
from pathlib import Path
import socket
import time

MAX_REPLY = 16 * 1024 * 1024


def call(*args, json_output=False, path=None, timeout=2):
    words = [str(arg) for arg in args if arg != '-j']
    if not words or any('\0' in word or '\n' in word for word in words):
        raise ValueError('Invalid compositor request')
    if path is None:
        path = Path(os.environ['XDG_RUNTIME_DIR']) / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    payload = (('j/' if json_output else '/') + ' '.join(words)).encode()
    deadline = time.monotonic() + timeout
    data = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(str(path))
        connection.sendall(payload)
        while True:
            connection.settimeout(max(.001, deadline - time.monotonic()))
            chunk = connection.recv(65536)
            if not chunk: break
            data.extend(chunk)
            if len(data) > MAX_REPLY: raise RuntimeError('Compositor reply is too large')
            if time.monotonic() >= deadline: raise TimeoutError('Compositor reply timed out; request not retried')
    text = data.decode().strip()
    if json_output: return json.loads(text)
    if text.lower() != 'ok': raise RuntimeError(text or 'Empty compositor response; request not retried')
    return text
