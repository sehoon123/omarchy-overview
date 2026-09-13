#!/usr/bin/env python3
"""One resident stdin/stdout worker. No listening socket, polling CLI or replay.

The reader stays responsive to frame/cancel messages while the executor owns
one serialized transaction. Only preview work is cooperatively cancellable.
"""
import fcntl
import json
import queue
import signal
import sys
import threading
import time

import controller
import preview

MAX_PACKET = 1024 * 1024
ARITY = {'state': 1, 'create': 1, 'move': 3, 'switch': 2, 'step': 2,
         'reorder': 3, 'remove': 2, 'undo': 2, 'prime': 2}


class Gate:
    def __init__(self, ident, emit):
        self.ident, self.emit = ident, emit
        self.cancelled = threading.Event()
        self.frame = threading.Event()

    def cancel(self):
        self.cancelled.set()
        self.frame.set()

    def wait_for_frame(self, addr, timeout):
        if self.cancelled.is_set(): return False
        self.emit({'event': 'frame-needed', 'id': self.ident, 'address': addr})
        return self.frame.wait(timeout) and not self.cancelled.is_set()


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
            if kind in ('frame', 'cancel'):
                if self.active and self.active[0]['id'] == ident and self.active[0]['args'][0] == 'prime':
                    if kind == 'cancel': self.active[1].cancel()
                    else: self.active[1].frame.set()
                return
            # An in-flight duplicate must not emit an early terminal reply for
            # the original operation. Its one real completion is still pending.
            if kind == 'request' and self.active and self.active[0]['id'] == ident: return
            args = packet.get('args')
            if kind != 'request' or not isinstance(args, list) or not args or not all(isinstance(a, str) for a in args):
                raise ValueError('Invalid command')
            if args[0] not in ARITY or len(args) != ARITY[args[0]]: raise ValueError('Unsupported command or arity')
            if ident <= self.last_id: raise ValueError('Request already seen; not replayed')
            if self.closed or self.active: raise ValueError('Worker is busy')
            if not isinstance(packet.get('cover', {}), dict): raise ValueError('Invalid viewport lease')
            self.last_id = ident
            job = (packet, Gate(ident, self.emit))
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
                    if gate.cancelled.wait(.025): return {'ok': True, 'primed': False}
                    if time.monotonic() >= lock_deadline: raise RuntimeError('Another desktop action is still running')
            if packet['args'][0] == 'prime':
                return {'ok': True, 'primed': preview.prime(controller, packet['args'][1], packet.get('cover', {}), gate)}
            return controller.act(packet['args'])

    def run(self):
        while True:
            job = self.jobs.get()
            if job is None: return
            packet, gate = job
            start = time.monotonic()
            try: result = self.execute(packet, gate)
            except Exception as error: result = {'ok': False, 'error': str(error), 'replayed': False}
            result.update(id=packet['id'], elapsedMs=round((time.monotonic() - start) * 1000, 1))
            with self.lock: self.active = None
            self.emit(result)

    def close(self):
        with self.lock:
            self.closed = True
            if self.active: self.active[1].cancel()
        self.jobs.put(None)
        self.thread.join()


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
            if len(line) > MAX_PACKET: raise ValueError('Protocol packet is too large')
            packet = None
            try:
                packet = json.loads(line)
                worker.accept(packet)
            except (ValueError, TypeError) as error:
                emit({'id': packet.get('id', 0) if isinstance(packet, dict) else 0, 'ok': False, 'error': str(error)})
    finally:
        worker.close()

if __name__ == '__main__': main()
