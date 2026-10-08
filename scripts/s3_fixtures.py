"""Real HTTPS/SigV4 integration tests against one disposable, loopback MinIO server.

The server is test-only AGPLv3, not an app dependency. Credentials, certificates,
data and logs are created in an owned TemporaryDirectory and removed in finally.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import ipaddress
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import tempfile
import time
from urllib.error import URLError
from urllib.parse import quote
from urllib.request import Request, urlopen, build_opener, HTTPSHandler, ProxyHandler
import xml.etree.ElementTree as ET

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parent.parent

def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def signature(key, message):
    return hmac.new(key, message.encode(), hashlib.sha256).digest()

with tempfile.TemporaryDirectory(prefix='aethertransfer-s3-fixture-') as temporary:
    directory = Path(temporary)
    certificates = directory / 'certificates'; certificates.mkdir()
    data = directory / 'data'; data.mkdir()
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'AetherTransfer isolated S3 fixture')])
    certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(datetime.now(timezone.utc) - timedelta(minutes=1))
        .not_valid_after(datetime.now(timezone.utc) + timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True).sign(key, hashes.SHA256()))
    ca = certificates / 'public.crt'; ca.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    private = certificates / 'private.key'
    private.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    private.chmod(0o600)
    access, secret = 'fixture-' + secrets.token_hex(12), secrets.token_hex(32)
    api_port, console_port = port(), port()
    while console_port == api_port: console_port = port()
    host = f'127.0.0.1:{api_port}'
    environment = {name: value for name, value in os.environ.items() if not name.startswith('MINIO_')}
    environment.update(MINIO_ROOT_USER=access, MINIO_ROOT_PASSWORD=secret, MINIO_BROWSER='off', MINIO_UPDATE='off')
    log = open(directory / 'server.log', 'wb')
    server = subprocess.Popen([str(ROOT / '.build/s3-fixture/minio'), '--certs-dir', str(certificates),
        'server', str(data), '--address', host, '--console-address', f'127.0.0.1:{console_port}', '--quiet'],
        env=environment, stdout=log, stderr=subprocess.STDOUT)
    context = ssl.create_default_context(cafile=ca)
    opener = build_opener(ProxyHandler({}), HTTPSHandler(context=context))
    bucket = 'aethertransfer-fixture'
    def request(path, body=b'', method='PUT'):
        """Independent standard-library SigV4 signer seeds the real service."""
        instant = datetime.now(timezone.utc)
        amz_date, day = instant.strftime('%Y%m%dT%H%M%SZ'), instant.strftime('%Y%m%d')
        digest = hashlib.sha256(body).hexdigest()
        uri, separator, query = path.partition('?')
        canonical = (f'{method}\n{uri}\n{query}\nhost:{host}\nx-amz-content-sha256:{digest}\nx-amz-date:{amz_date}\n\n'
                     f'host;x-amz-content-sha256;x-amz-date\n{digest}')
        scope = f'{day}/us-east-1/s3/aws4_request'
        signing = signature(signature(signature(signature(('AWS4' + secret).encode(), day), 'us-east-1'), 's3'), 'aws4_request')
        value = hmac.new(signing, f'AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'.encode(), hashlib.sha256).hexdigest()
        headers = {'Host': host, 'x-amz-content-sha256': digest, 'x-amz-date': amz_date,
                   'Authorization': f'AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature={value}'}
        with opener.open(Request(f'https://{host}{path}', body if method == 'PUT' else None, headers, method=method), timeout=15) as response:
            if response.status != 200: raise RuntimeError('Unexpected fixture seed status')
            return response.read(4 * 1024 * 1024)
    try:
        for attempt in range(100):
            if server.poll() is not None: raise RuntimeError('Isolated S3 server exited before becoming ready; private log will be removed')
            try:
                with opener.open(f'https://{host}/minio/health/live', timeout=1) as response:
                    if response.status == 200: break
            except (URLError, TimeoutError, OSError): time.sleep(.1)
        else: raise RuntimeError('Isolated S3 server did not become ready')
        request('/' + bucket)
        seeds = [(f'pages/item-{number:04}.txt', f'page-{number}'.encode()) for number in range(1005)]
        seeds += [('keys/中文 空格+#%?.txt', b'exact-key'), ('same', b'object'), ('same/child', b'prefix')]
        with ThreadPoolExecutor(max_workers=4) as workers:
            list(workers.map(lambda item: request('/' + bucket + '/' + quote(item[0], safe='/-._~'), item[1]), seeds))
        # Independently expose this fixture's root object/prefix projection. It does
        # not substitute for actual AWS/R2 acceptance of overlapping namespaces.
        listing = ET.fromstring(request('/' + bucket + '/?delimiter=%2F&encoding-type=url&list-type=2', method='GET'))
        ns = {'s3': 'http://s3.amazonaws.com/doc/2006-03-01/'}
        names = [node.text for node in listing.findall('s3:Contents/s3:Key', ns)]
        prefixes = [node.text for node in listing.findall('s3:CommonPrefixes/s3:Prefix', ns)]
        print(f'Independent signed fixture root: objects={names}, prefixes={prefixes}', flush=True)
        test_environment = os.environ.copy()
        test_environment.update(AT_S3_PORT=str(api_port), AT_S3_ACCESS_KEY=access, AT_S3_SECRET_KEY=secret,
                                AT_S3_BUCKET=bucket, AT_S3_CA=str(ca))
        print('Real isolated HTTPS S3 service ready; 1,008 seeded objects; credentials and fixture data are ephemeral.', flush=True)
        result = subprocess.run(['swift', 'test', '--filter', 'S3ProtocolTests'], cwd=ROOT, env=test_environment)
    finally:
        server.terminate()
        try: server.wait(timeout=10)
        except subprocess.TimeoutExpired: server.kill(); server.wait(timeout=5)
        log.close()
print('S3 server stopped; owned credentials, certificates, data and logs removed.', flush=True)
raise SystemExit(result.returncode)
