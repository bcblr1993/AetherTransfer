"""Run Swift integration tests against disposable loopback FTP/SFTP/WebDAV servers."""
import errno
import logging
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import json
import sys
import ipaddress
from datetime import datetime, timedelta, timezone

import paramiko
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer
from wsgidav.wsgidav_app import WsgiDAVApp
from cheroot.wsgi import Server as DAVServer
from cheroot.ssl.builtin import BuiltinSSLAdapter
from cheroot.server import HTTPConnection

logging.disable(logging.CRITICAL)

class DAVConnection(HTTPConnection):
    def close(self):
        # Cheroot leaves the writer to GC; close it before its transport, including
        # when a deliberate client cancellation left an unsent response in it.
        try: self.wfile.close()
        except OSError: pass
        super().close()

    def _close_kernel_socket(self):
        # Complete TLS shutdown rather than closing TCP without close_notify.
        if isinstance(self.socket, ssl.SSLSocket):
            self.socket.settimeout(.25)
            try:
                transport = self.socket.unwrap()
                try: transport.shutdown(socket.SHUT_RDWR)
                except OSError: pass
                transport.close()
                return
            except (OSError, ssl.SSLError): pass
        super()._close_kernel_socket()

class Authentication(paramiko.ServerInterface):
    accepted_key = None
    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == 'fixture' and password == 'fixture-only' else paramiko.AUTH_FAILED
    def get_allowed_auths(self, username):
        return 'password,publickey'
    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == 'fixture' and key == self.accepted_key else paramiko.AUTH_FAILED
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
    certificates = Path(directory)
    root = certificates / 'files'; root.mkdir()
    tls_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'AetherTransfer isolated fixture')])
    certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(tls_key.public_key())
                   .serial_number(x509.random_serial_number()).not_valid_before(datetime.now(timezone.utc) - timedelta(minutes=1))
                   .not_valid_after(datetime.now(timezone.utc) + timedelta(days=1))
                   .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
                   .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True).sign(tls_key, hashes.SHA256()))
    cert_file = certificates / 'certificate.pem'; cert_file.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    key_file = certificates / 'tls-key.pem'
    key_file.write_bytes(tls_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    key_file.chmod(0o600)
    (root / '中文 seed.txt').write_text('fixture content', encoding='utf8')
    authorizer = DummyAuthorizer()
    authorizer.add_user('fixture', 'fixture-only', str(root), perm='elradfmwMT')
    class Handler(FTPHandler): pass
    Handler.authorizer = authorizer
    ftp = FTPServer(('127.0.0.1', 0), Handler)
    class TLSHandler(TLS_FTPHandler): pass
    TLSHandler.authorizer = authorizer
    TLSHandler.certfile = str(cert_file); TLSHandler.keyfile = str(key_file)
    TLSHandler.tls_control_required = True; TLSHandler.tls_data_required = True
    ftpes = FTPServer(('127.0.0.1', 0), TLSHandler)
    class ImplicitTLSHandler(TLSHandler):
        def on_connect(self):
            self.secure_connection(self.ssl_context)
    ftps = FTPServer(('127.0.0.1', 0), ImplicitTLSHandler)
    stopping = threading.Event()
    def serve_ftp():
        while not stopping.is_set():
            ftp.serve_forever(timeout=.1, blocking=False, handle_exit=False)
    ftp_thread = threading.Thread(target=serve_ftp, daemon=True)
    ftp_thread.start()
    key = paramiko.RSAKey.generate(2048)
    client_key = paramiko.RSAKey.generate(2048)
    Authentication.accepted_key = client_key
    client_key_file = certificates / 'client-key.pem'
    client_key.write_private_key_file(str(client_key_file), password='fixture-passphrase')
    client_key_file.chmod(0o600)
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
    dav_servers = []
    dav_threads = []
    def serve_dav(tls=False, digest=False):
        app = WsgiDAVApp({
            'provider_mapping': {'/': str(root)},
            'simple_dc': {'user_mapping': {'*': {'fixture': {'password': 'fixture-only'}}}},
            'http_authenticator': {'accept_basic': not digest, 'accept_digest': digest, 'default_to_digest': digest},
            'dir_browser': {'enable': False}, 'logging': {'enable': False}, 'verbose': 0,
        })
        def faults(environ, start_response):
            # Independent fault responses verify that redirects and partial mutation failures cannot be reported as success.
            if environ['PATH_INFO'].rstrip('/') == '/__aether_fixture_redirect__':
                start_response('307 Temporary Redirect', [('Location', 'http://127.0.0.1:1/downgrade'), ('Content-Length', '0')])
                return [b'']
            if environ['PATH_INFO'] == '/__aether_fixture_partial__' and environ['REQUEST_METHOD'] == 'DELETE':
                body = b'<d:multistatus xmlns:d="DAV:"><d:response><d:href>/missing</d:href><d:status>HTTP/1.1 403 Forbidden</d:status></d:response></d:multistatus>'
                start_response('207 Multi-Status', [('Content-Type', 'application/xml'), ('Content-Length', str(len(body)))])
                return [body]
            path = environ['PATH_INFO']
            if environ['REQUEST_METHOD'] == 'GET' and environ.get('HTTP_RANGE') and path.startswith('/__aether_fixture_range_'):
                body = (root / path.lstrip('/')).read_bytes()
                headers = [('Content-Length', str(len(body)))]
                if path.startswith('/__aether_fixture_range_bad__'):
                    headers.append(('Content-Range', f'bytes 1-{len(body)-1}/{len(body)}'))
                    start_response('206 Partial Content', headers)
                else:
                    start_response('200 OK', headers)
                return [body]
            response = app(environ, start_response)
            if environ['REQUEST_METHOD'] == 'HEAD':
                # WsgiDAV's authentication middleware yields a challenge body even for HEAD.
                # A real HEAD response has no body (RFC 9110 section 9.3.2).
                try:
                    for _ in response: pass
                finally:
                    if hasattr(response, 'close'): response.close()
                return [b'']
            return response
        server = DAVServer(('127.0.0.1', 0), faults, numthreads=4)
        server.ConnectionClass = DAVConnection
        if tls:
            server.ssl_adapter = BuiltinSSLAdapter(str(cert_file), str(key_file))
        server.prepare()
        thread = threading.Thread(target=server.serve, daemon=True); thread.start()
        dav_servers.append(server); dav_threads.append(thread)
        return server.socket.getsockname()[1]
    dav_port = serve_dav()
    dav_tls_port = serve_dav(tls=True, digest=True)
    dav_digest_port = serve_dav(digest=True)
    env = os.environ.copy()
    env.update(AT_FTP_PORT=str(ftp.socket.getsockname()[1]), AT_SFTP_PORT=str(listener.getsockname()[1]),
               AT_SFTP_KEY=key.get_base64(), AT_FTPES_PORT=str(ftpes.socket.getsockname()[1]),
               AT_FTPS_PORT=str(ftps.socket.getsockname()[1]), AT_TLS_CA=str(cert_file), AT_SFTP_PRIVATE_KEY=str(client_key_file),
               AT_WEBDAV_PORT=str(dav_port), AT_WEBDAVS_PORT=str(dav_tls_port), AT_WEBDAV_DIGEST_PORT=str(dav_digest_port))
    try:
        if '--serve' in sys.argv:
            report = Path('reports/fixture.json')
            report.parent.mkdir(exist_ok=True)
            report.write_text(json.dumps({'ftp': int(env['AT_FTP_PORT']), 'sftp': int(env['AT_SFTP_PORT']), 'webdav': dav_port,
                                         'webdavs': dav_tls_port, 'key': env['AT_SFTP_KEY'], 'root': str(root)}))
            print('Disposable loopback protocol fixtures ready.', flush=True)
            try: threading.Event().wait()
            except KeyboardInterrupt: pass
            result = None
        else:
            result = subprocess.run(['swift', 'test', '--filter', 'ProtocolIntegrationTests'], env=env)
    finally:
        stopping.set(); ftp_thread.join(timeout=2)
        ftp.close_all(); ftpes.close_all(); ftps.close_all(); listener.close()
        for transport in transports: transport.close()
        for server in dav_servers: server.stop()
        for thread in dav_threads: thread.join(timeout=2)
    raise SystemExit(result.returncode if result else 0)
