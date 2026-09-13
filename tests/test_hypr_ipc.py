from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hypr_ipc

class SocketTests(unittest.TestCase):
    def test_fragmented_reply_and_exact_wire_format(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'ipc.sock')
            received = []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path); server.listen(1)
                def serve():
                    with server.accept()[0] as connection:
                        received.append(connection.recv(4096))
                        connection.sendall(b'[{"id":')
                        connection.sendall(b'1}]')
                thread = threading.Thread(target=serve); thread.start()
                self.assertEqual(hypr_ipc.call('-j', 'workspaces', json_output=True, path=path), [{'id': 1}])
                thread.join(timeout=1)
                self.assertEqual(received, [b'j/workspaces'])

    def test_rejects_framing_characters(self):
        for arg in ['bad\nrequest', 'bad\0request']:
            with self.assertRaises(ValueError): hypr_ipc.call(arg, path='/not-used')

if __name__ == '__main__': unittest.main()
