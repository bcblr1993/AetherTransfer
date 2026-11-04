"""Run Swift integration tests against disposable loopback FTP/FTPS/SFTP servers."""
import errno
import datetime
import ipaddress
import sys
import logging
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

import paramiko
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.ioloop import IOLoop
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from pyftpdlib.servers import FTPServer

logging.disable(logging.CRITICAL)

class Authentication(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == 'fixture' and password == 'fixture-only' else paramiko.AUTH_FAILED
    def get_allowed_auths(self, username):
        return 'password'
    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

class Files(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, root, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.root = Path(root).resolve()
    def path(self, remote):
        p = (self.root / remote.lstrip('/')).resolve()
        if not p.is_relative_to(self.root):
            raise PermissionError(errno.EACCES, 'Outside fixture')
        return p
    def list_folder(self, path):
        try:
            result = []
            for p in self.path(path).iterdir():
                attrs = paramiko.SFTPAttributes.from_stat(p.lstat())
                attrs.filename = p.name
                result.append(attrs)
            return result
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    def stat(self, path):
        try: return paramiko.SFTPAttributes.from_stat(self.path(path).stat())
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    lstat = stat
    def open(self, path, flags, attrs):
        try:
            fd = os.open(self.path(path), flags, getattr(attrs, 'st_mode', None) or 0o600)
            file = os.fdopen(fd, 'r+b' if flags & os.O_RDWR else ('wb' if flags & os.O_WRONLY else 'rb'))
            handle = paramiko.SFTPHandle(flags)
            handle.readfile = file; handle.writefile = file
            return handle
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    def remove(self, path):
        try: self.path(path).unlink(); return paramiko.SFTP_OK
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    def rename(self, source, target):
        try: self.path(source).rename(self.path(target)); return paramiko.SFTP_OK
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    def mkdir(self, path, attrs):
        try: self.path(path).mkdir(); return paramiko.SFTP_OK
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)
    def rmdir(self, path):
        try: self.path(path).rmdir(); return paramiko.SFTP_OK
        except OSError as e: return paramiko.SFTPServer.convert_errno(e.errno)

with tempfile.TemporaryDirectory(prefix='aethertransfer-fixture-') as directory:
    root = Path(directory)
    (root / '中文 seed.txt').write_text('fixture content', encoding='utf8')
    authorizer = DummyAuthorizer()
    authorizer.add_user('fixture', 'fixture-only', str(root), perm='elradfmwMT')
    class Handler(FTPHandler): pass
    Handler.authorizer = authorizer
    ftp = FTPServer(('127.0.0.1', 0), Handler)
    stopping = threading.Event()
    def serve(server):
        while not stopping.is_set():
            server.ioloop.loop(timeout=.1, blocking=False)
        server.close_all()
    ftp_thread = threading.Thread(target=serve, args=(ftp,), daemon=True)
    ftp_thread.start()
    tls_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(tls_key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(minutes=5))
            .not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"),
                           x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .sign(tls_key, hashes.SHA256()))
    cert_path = root / "fixture-ca.pem"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path = root / "fixture-key.pem"
    key_path.write_bytes(tls_key.private_bytes(serialization.Encoding.PEM,
                         serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    key_path.chmod(0o600)
    class ImplicitTLSHandler(TLS_FTPHandler):
        certfile = str(cert_path)
        keyfile = str(key_path)
        tls_control_required = True
        tls_data_required = True
        def handle(self):
            self.secure_connection(self.ssl_context)
            super().handle()
    ImplicitTLSHandler.authorizer = authorizer
    tls_loop = IOLoop()
    ftps = FTPServer(('127.0.0.1', 0), ImplicitTLSHandler, ioloop=tls_loop)
    ftps_thread = threading.Thread(target=serve, args=(ftps,), daemon=True)
    ftps_thread.start()
    key = paramiko.RSAKey.generate(2048)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0)); listener.listen(16)
    transports = []
    def handle(connection):
        transport = paramiko.Transport(connection)
        transports.append(transport)
        transport.add_server_key(key)
        transport.set_subsystem_handler('sftp', paramiko.SFTPServer, Files, root=root)
        try: transport.start_server(server=Authentication())
        except (EOFError, paramiko.SSHException): transport.close()
    def accept():
        while True:
            try: connection, _ = listener.accept()
            except OSError: return
            threading.Thread(target=handle, args=(connection,), daemon=True).start()
    threading.Thread(target=accept, daemon=True).start()
    env = os.environ.copy()
    env.update(AT_FTP_PORT=str(ftp.socket.getsockname()[1]), AT_SFTP_PORT=str(listener.getsockname()[1]),
               AT_SFTP_KEY=key.get_base64(), AT_FTPS_PORT=str(ftps.socket.getsockname()[1]),
               AT_FTPS_CA=str(cert_path))
    try:
        result = subprocess.run(['swift', 'test', '--filter', 'ProtocolIntegrationTests|FTPSIntegrationTests'], env=env)
    finally:
        stopping.set()
        ftp_thread.join(timeout=5)
        ftps_thread.join(timeout=5)
        try: listener.close()
        except Exception: pass
        for transport in transports:
            try: transport.close()
            except Exception: pass
    sys.exit(result.returncode)
