"""Private SOCKS/TLS upstream for real, certificate-verified router health checks."""
import http.server
import select
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading
from pathlib import Path


def receive(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError()
        data += chunk
    return data


class SocksHandler(socketserver.BaseRequestHandler):
    def handle(self):
        upstream = None
        try:
            self.request.settimeout(5)
            version, count = receive(self.request, 2)
            assert version == 5 and 0 in receive(self.request, count)
            self.request.sendall(b"\x05\x00")
            version, command, _, kind = receive(self.request, 4)
            assert version == 5 and command == 1
            if kind == 1:
                host = socket.inet_ntoa(receive(self.request, 4))
            elif kind == 3:
                host = receive(self.request, receive(self.request, 1)[0]).decode()
            else:
                return
            port = int.from_bytes(receive(self.request, 2), "big")
            if not self.server.enabled or host != "198.18.0.1" or port != self.server.tls_port:
                self.request.sendall(b"\x05\x04\x00\x01" + bytes(6))
                return
            upstream = socket.create_connection(("127.0.0.1", port), timeout=5)
            self.server.requests += 1
            self.request.sendall(b"\x05\x00\x00\x01" + bytes(6))
            while True:
                ready = select.select([self.request, upstream], [], [], 5)[0]
                if not ready:
                    return
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (upstream if source is self.request else self.request).sendall(data)
        except (OSError, EOFError, AssertionError):
            pass
        finally:
            if upstream:
                upstream.close()


class SocksServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


class TLSHandler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


class Upstream:
    def __init__(self):
        self.directory = tempfile.TemporaryDirectory(prefix="passwall-tls-")
        path = Path(self.directory.name)
        self.cert = path / "cert.pem"
        key = path / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(self.cert), "-days", "2",
                        "-subj", "/CN=PassWall disposable test endpoint",
                        "-addext", "subjectAltName=IP:198.18.0.1,IP:10.78.0.2"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), TLSHandler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.cert, key)
        self.http.socket = context.wrap_socket(self.http.socket, server_side=True)
        self.tls_port = self.http.server_port
        self.nodes = {}
        self.servers = [self.http]
        for name in ("good_a", "bad_b", "good_c"):
            server = SocksServer(("127.0.0.1", 0), SocksHandler)
            server.tls_port = self.tls_port
            server.enabled = name != "bad_b"
            server.requests = 0
            self.nodes[name] = server
            self.servers.append(server)
        for server in self.servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()

    def setup(self):
        script = "cat >> /etc/ssl/certs/ca-certificates.crt <<'CERT'\n" + self.cert.read_text() + "CERT\n"
        for name, server in self.nodes.items():
            script += f"""
uci set passwall.{name}=nodes
uci set passwall.{name}.type=Xray
uci set passwall.{name}.protocol=socks
uci set passwall.{name}.address=10.77.0.2
uci set passwall.{name}.port={server.server_address[1]}
"""
        return script + f"""
uci set passwall.@global[0].enabled=1
uci set passwall.@global[0].acl_enable=0
uci set passwall.@global[0].node=good_a
uci set passwall.@global[0].switch_guard=1
uci set passwall.@global[0].switch_guard_probe_url=https://198.18.0.1:{self.tls_port}/generate_204
uci set passwall.@global[0].use_gfw_list=0
uci set passwall.@global[0].use_proxy_list=0
uci set passwall.@global[0].use_direct_list=0
uci set passwall.@global[0].use_block_list=0
uci set passwall.@global[0].chn_list=0
uci set passwall.@global[0].dns_shunt=chinadns-ng
uci set passwall.@global[0].dns_mode=xray
uci set passwall.@global[0].v2ray_dns_mode=tcp
uci set passwall.@global[0].remote_dns=1.1.1.1
uci commit passwall
"""

    def close(self):
        for server in self.servers:
            server.shutdown()
            server.server_close()
        self.directory.cleanup()
