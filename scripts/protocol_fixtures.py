"""Run Swift integration tests against disposable loopback FTP/SFTP servers."""
import errno
import logging
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import json
import sys

import paramiko
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
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
    def serve_ftp():
        while not stopping.is_set():
            ftp.serve_forever(timeout=.1, blocking=False, handle_exit=False)
    ftp_thread = threading.Thread(target=serve_ftp, daemon=True)
    ftp_thread.start()
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
               AT_SFTP_KEY=key.get_base64())
    try:
        if '--serve' in sys.argv:
            report = Path('reports/fixture.json')
            report.parent.mkdir(exist_ok=True)
            report.write_text(json.dumps({'ftp': int(env['AT_FTP_PORT']), 'sftp': int(env['AT_SFTP_PORT']), 'key': env['AT_SFTP_KEY'], 'root': str(root)}))
            print('Disposable loopback protocol fixtures ready.', flush=True)
            try: threading.Event().wait()
            except KeyboardInterrupt: pass
            result = None
        else:
            result = subprocess.run(['swift', 'test', '--filter', 'ProtocolIntegrationTests'], env=env)
    finally:
        stopping.set(); ftp_thread.join(timeout=2)
        ftp.close_all(); listener.close()
        for transport in transports: transport.close()
    raise SystemExit(result.returncode if result else 0)
