"""Bounded, local Hyprland IPC. Same wire format as hyprctl; no subprocesses.

`timeout` is **one wall-clock budget for the whole call** — path, connect, send
and every recv share it — so a helper that makes two calls can no longer wait
six times its nominal budget (AUDIT F-31). A request is never retried.

Every failure carries one bounded, non-leaking message (AUDIT F-27/F-28/F-29):
no path, no errno, no reply content, and nothing longer than `MAX_MESSAGE`.
Callers that already catch `RuntimeError`/`TimeoutError`/`ValueError` keep
working: `Unreachable` and `Unreadable` are `RuntimeError`s and `ReplyTimeout`
is a `TimeoutError`.
"""
import json
import os
from pathlib import Path
import socket
import time

MAX_REPLY = 16 * 1024 * 1024
MAX_MESSAGE = 200


class Unreachable(RuntimeError):
    """No usable socket: the session environment, the path or the peer is gone."""


class Unreadable(RuntimeError):
    """A reply arrived that cannot be decoded, parsed or bounded."""


class ReplyTimeout(TimeoutError):
    """The one budget expired before a complete reply arrived. Never retried."""


def summary(text):
    """One bounded, single-line message. A 16 MiB reply must not become a toast."""
    raw = str(text)
    head = ''.join(character if character.isprintable() else ' ' for character in raw[:2 * MAX_MESSAGE])
    cleaned = ' '.join(head.split())
    if len(raw) > 2 * MAX_MESSAGE or len(cleaned) > MAX_MESSAGE:
        return cleaned[:MAX_MESSAGE - 1] + '…'
    return cleaned


def budget(deadline):
    """What is left of the one call budget. Never 0: that would mean non-blocking."""
    return max(.001, deadline - time.monotonic())


def socket_path():
    runtime, signature = os.environ.get('XDG_RUNTIME_DIR'), os.environ.get('HYPRLAND_INSTANCE_SIGNATURE')
    if not runtime or not signature:
        # Name the missing role, never the value: this string reaches a toast.
        raise Unreachable('Hyprland session environment is unavailable')
    return Path(runtime) / 'hypr' / signature / '.socket.sock'


def interpret(data, json_output, expired):
    """Read the bytes that did arrive; a complete reply is never discarded.

    `expired` records that the budget ran out rather than the peer closing, so a
    reply that is already complete (it parses, or it is `ok`) still counts, and
    only a genuinely unfinished one is reported as a timeout (AUDIT F-30).
    """
    try:
        text = data.decode().strip()
    except UnicodeDecodeError:
        text = None
    if text is not None:
        if json_output:
            try:
                return json.loads(text)
            except ValueError:
                pass
        elif text.lower() == 'ok':
            return text
        elif text:
            # The compositor's own refusal is more actionable than "timed out", so
            # it is reported even on a late reply — bounded, on one line. A reply
            # with nothing printable in it is not a message: fall through instead
            # of raising an empty one.
            refusal = summary(text)
            if refusal:
                raise RuntimeError(refusal)
    if expired:
        raise ReplyTimeout('Hyprland did not answer in time; the request was not retried')
    if not data:
        raise Unreadable('Empty compositor response; request not retried')
    raise Unreadable('Hyprland sent a reply Overview could not read')


def call(*args, json_output=False, path=None, timeout=2):
    words = [str(arg) for arg in args if arg != '-j']
    if not words or any('\0' in word or '\n' in word for word in words):
        raise ValueError('Invalid compositor request')
    deadline = time.monotonic() + timeout
    if path is None:
        path = socket_path()
    payload = (('j/' if json_output else '/') + ' '.join(words)).encode()
    data = bytearray()
    expired = False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(budget(deadline))
            connection.connect(str(path))
            connection.settimeout(budget(deadline))
            connection.sendall(payload)
            while True:
                if time.monotonic() >= deadline:
                    expired = True
                    break
                connection.settimeout(budget(deadline))
                try:
                    chunk = connection.recv(65536)
                except TimeoutError:
                    expired = True
                    break
                if not chunk: break
                data.extend(chunk)
                if len(data) > MAX_REPLY: raise Unreadable('Compositor reply is too large')
    except TimeoutError:
        # connect()/sendall() spent the same budget: nothing was answered yet.
        raise ReplyTimeout('Hyprland did not answer in time; the request was not retried') from None
    except OSError:
        # Missing socket, refused socket, reset peer: one message, no errno, no path.
        raise Unreachable('Hyprland is not reachable') from None
    return interpret(bytes(data), json_output, expired)
