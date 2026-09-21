#!/usr/bin/env python3
"""One resident stdin/stdout worker. No listening socket, polling CLI or replay.

One serialized desktop transaction at a time. Preview capture is a separate,
read-only output helper; this worker never scrolls desktops to obtain previews.

Every protocol error is answered, never fatal: an oversized packet is refused
politely and the rest of that line is drained instead of being parsed as a new
request (AUDIT F-37), a retransmission that changes its arguments is refused
instead of being swallowed (F-38), and a transaction that returns something
unusable, raises, or cannot be emitted still ends with exactly one reply, a
cleared slot and a live thread (F-36). `close()` is bounded and idempotent
(F-39); mutating requests are never replayed.
"""
import fcntl
import json
import queue
import signal
import sys
import threading
import time

import controller

MAX_PACKET = 1024 * 1024
MAX_MESSAGE = 200
CLOSE_TIMEOUT = 2
ARITY = {'state': 1, 'create': 1, 'move': 3, 'switch': 2, 'step': 2,
         'reorder': 3, 'remove': 2, 'undo': 2}


def message(error):
    """One bounded, single-line error string for the protocol and the toast."""
    text = ' '.join(str(error)[:2 * MAX_MESSAGE].split())
    if len(str(error)) > 2 * MAX_MESSAGE or len(text) > MAX_MESSAGE:
        text = text[:MAX_MESSAGE - 1] + '…'
    return text or 'Overview backend could not complete that request'


class Gate:
    def __init__(self):
        self.cancelled = threading.Event()

    def cancel(self):
        self.cancelled.set()


class Worker:
    def __init__(self, emit, execute=None):
        self.emit = emit
        self.execute = execute or self.run_transaction
        self.jobs = queue.Queue(maxsize=1)
        self.lock = threading.Lock()
        self.active = None
        self.last_id = 0
        self.closed = False
        self.thread = threading.Thread(target=self.run, name='overview-transactions', daemon=False)
        self.thread.start()

    def accept(self, packet):
        if not isinstance(packet, dict): raise ValueError('Expected an object')
        ident = packet.get('id')
        if type(ident) is not int or not 0 < ident < 2147483647: raise ValueError('Invalid request id')
        kind = packet.get('type', 'request')
        with self.lock:
            # An in-flight duplicate must not emit an early terminal reply for
            # the original operation. Its one real completion is still pending.
            # A retransmission that changes the request is not that duplicate:
            # answer it instead of silently discarding it.
            if kind == 'request' and self.active and self.active[0]['id'] == ident:
                if packet.get('args') == self.active[0].get('args'): return
                raise ValueError('Conflicting retransmission')
            args = packet.get('args')
            if kind != 'request' or not isinstance(args, list) or not args or not all(isinstance(a, str) for a in args):
                raise ValueError('Invalid command')
            if args[0] not in ARITY or len(args) != ARITY[args[0]]: raise ValueError('Unsupported command or arity')
            if ident <= self.last_id: raise ValueError('Request already seen; not replayed')
            if self.closed or self.active: raise ValueError('Worker is busy')
            if not isinstance(packet.get('cover', {}), dict): raise ValueError('Invalid viewport lease')
            if not isinstance(packet.get('monitor', ''), str): raise ValueError('Invalid monitor')
            self.last_id = ident
            job = (packet, Gate())
            self.active = job
            self.jobs.put_nowait(job)

    @staticmethod
    def run_transaction(packet, gate):
        controller.STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (controller.STATE / 'actions.lock').open('a') as lock:
            # Never make cancellation wait behind a different CLI transaction.
            lock_deadline = time.monotonic() + 2
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if gate.cancelled.wait(.025): return {'ok': False, 'error': 'Overview is stopping'}
                    if time.monotonic() >= lock_deadline: raise RuntimeError('Another desktop action is still running')
            return controller.act(packet['args'], packet.get('monitor', ''))

    def run(self):
        while True:
            job = self.jobs.get()
            if job is None: return
            packet, gate = job
            start = time.monotonic()
            result = None
            try:
                result = self.execute(packet, gate)
            except BaseException as error:
                result = {'ok': False, 'error': message(error), 'replayed': False}
                # A SystemExit or KeyboardInterrupt still ends this thread, but
                # only after the reply below and never with `active` left set.
                if not isinstance(error, Exception): raise
            finally:
                # Everything after execute() is inside the guarded region: a
                # non-dict result or an unserialisable reply must not strand
                # `active`, kill this thread, or answer with no reply at all.
                if not isinstance(result, dict):
                    result = {'ok': False, 'error': 'Overview backend returned an unusable result', 'replayed': False}
                result.update(id=packet.get('id'), elapsedMs=round((time.monotonic() - start) * 1000, 1))
                with self.lock: self.active = None
                try: self.emit(result)
                except Exception: pass
            with self.lock:
                if self.closed: return

    def close(self, timeout=CLOSE_TIMEOUT):
        """Bounded and idempotent. Returns True when the thread actually ended.

        `timeout` is one budget for handing over the sentinel *and* joining, so a
        transaction that ignores its gate (controller.act has no ceiling of its
        own) keeps the process alive after this returns instead of silently
        extending the graceful-stop window.
        """
        deadline = time.monotonic() + timeout
        with self.lock:
            first, self.closed = not self.closed, True
            if self.active: self.active[1].cancel()
        if first:
            # A blocking put would wait forever on a job nobody will ever run.
            try: self.jobs.put(None, timeout=max(.001, deadline - time.monotonic()))
            except queue.Full: pass
        self.thread.join(max(0, deadline - time.monotonic()))
        return not self.thread.is_alive()


def main():
    output_lock = threading.Lock()
    def emit(packet):
        with output_lock:
            try: print(json.dumps(packet, separators=(',', ':')), flush=True)
            except BrokenPipeError: pass
    def terminate(signum, frame): raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate)
    worker = Worker(emit)
    emit({'event': 'ready', 'protocol': 1})
    try:
        while line := sys.stdin.buffer.readline(MAX_PACKET + 1):
            packet = None
            try:
                if len(line) > MAX_PACKET:
                    # Drain the rest of the oversized line so its tail is never
                    # read as a second request, then refuse it like any other.
                    while not line.endswith(b'\n'):
                        line = sys.stdin.buffer.readline(MAX_PACKET + 1)
                        if not line: break
                    raise ValueError('Protocol packet is too large')
                packet = json.loads(line)
                worker.accept(packet)
            except (ValueError, TypeError) as error:
                emit({'id': packet.get('id', 0) if isinstance(packet, dict) else 0,
                      'ok': False, 'error': message(error)})
    finally:
        worker.close()

if __name__ == '__main__': main()
