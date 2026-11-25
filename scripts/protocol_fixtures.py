"""Run Swift integration tests against disposable loopback protocol servers."""
import base64
import datetime
import email.utils
import errno
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import logging
import os
from pathlib import Path
import posixpath
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import uuid
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape as xml_escape

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
import paramiko
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.ioloop import IOLoop
from pyftpdlib.servers import FTPServer

logging.disable(logging.CRITICAL)

FIXTURE_USER = "fixture"
FIXTURE_PASS = "fixture-only"
S3_ACCESS_KEY = "AKIAFIXTURE"
S3_SECRET_KEY = "secret-fixture-key"
S3_REGION = "us-east-1"
S3_BUCKET = "test-bucket"
STS_ACCESS_KEY = "ASIAFIXTURETEMP"
STS_SECRET_KEY = "sts-temp-secret-fixture-key"
STS_SESSION_TOKEN = "FwoGZXIvYXdzFixtureSessionToken"
STS_ROLE_ARN = "arn:aws:iam::123456789012:role/AetherFixtureRole"
B2_KEY_ID = "b2-key-fixture"
B2_APP_KEY = "b2-secret-fixture"
B2_ACCOUNT_ID = "acct-fixture"
B2_BUCKET_ID = "bkt-fixture-001"
B2_BUCKET_NAME = "test-b2-bucket"
AZURE_ACCOUNT = "fixtureacct"
AZURE_CONTAINER = "fixturecontainer"
AZURE_SHARED_KEY_BYTES = b"fixture-azure-shared-key-32bytes"
AZURE_SHARED_KEY_B64 = base64.b64encode(AZURE_SHARED_KEY_BYTES).decode("ascii")
SWIFT_TENANT = "fixtureproj"
SWIFT_USER = "fixture"
SWIFT_PASS = "fixture-only"
SWIFT_ACCOUNT = f"AUTH_{SWIFT_TENANT}"


def rfc1123(ts: float | None = None) -> str:
    return email.utils.formatdate(ts if ts is not None else datetime.datetime.now(datetime.timezone.utc).timestamp(), usegmt=True)


def iso8601_z(ts: float | None = None) -> str:
    dt = datetime.datetime.fromtimestamp(ts if ts is not None else datetime.datetime.now(datetime.timezone.utc).timestamp(), tz=datetime.timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def iso8601_micro(ts: float | None = None) -> str:
    dt = datetime.datetime.fromtimestamp(ts if ts is not None else datetime.datetime.now(datetime.timezone.utc).timestamp(), tz=datetime.timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")


def parse_range_header(range_header: str | None, total_len: int) -> tuple[int, int] | None:
    if not range_header or not range_header.startswith("bytes="):
        return None
    spec = range_header[6:].strip()
    if "," in spec or "-" not in spec:
        return None
    start_s, end_s = spec.split("-", 1)
    if start_s == "":
        return None
    start = int(start_s)
    end = total_len - 1 if end_s == "" else min(total_len - 1, int(end_s))
    if start < 0 or start > end or start >= total_len:
        return None
    return start, end


# ---------------------------------------------------------------------------
# SFTP Fixture Server (Paramiko)
# ---------------------------------------------------------------------------

class SFTPAuth(paramiko.ServerInterface):
    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == FIXTURE_USER and password == FIXTURE_PASS else paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "password"

    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


class SFTPFiles(paramiko.SFTPServerInterface):
    def __init__(self, server, *args, root, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.root = Path(root).resolve()

    def _raw_path(self, remote: str) -> Path:
        rel = posixpath.normpath("/" + remote).lstrip("/")
        candidate = self.root.joinpath(rel) if rel else self.root
        if not candidate.parent.resolve().is_relative_to(self.root) and candidate != self.root:
            raise PermissionError(errno.EACCES, "Outside fixture")
        return candidate

    def path(self, remote: str) -> Path:
        p = self._raw_path(remote).resolve()
        if not p.is_relative_to(self.root):
            raise PermissionError(errno.EACCES, "Outside fixture")
        return p

    def list_folder(self, path):
        try:
            result = []
            for p in self.path(path).iterdir():
                attrs = paramiko.SFTPAttributes.from_stat(p.lstat())
                attrs.filename = p.name
                result.append(attrs)
            return result
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self.path(path).stat())
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def lstat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self._raw_path(path).lstat())
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def open(self, path, flags, attrs):
        try:
            fd = os.open(self.path(path), flags, getattr(attrs, "st_mode", None) or 0o600)
            file = os.fdopen(fd, "r+b" if flags & os.O_RDWR else ("wb" if flags & os.O_WRONLY else "rb"))
            handle = paramiko.SFTPHandle(flags)
            handle.readfile = file
            handle.writefile = file
            return handle
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def remove(self, path):
        try:
            raw = self._raw_path(path)
            if raw.is_symlink():
                raw.unlink()
            else:
                self.path(path).unlink()
            return paramiko.SFTP_OK
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def rename(self, source, target):
        try:
            self._raw_path(source).rename(self._raw_path(target))
            return paramiko.SFTP_OK
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def mkdir(self, path, attrs):
        try:
            self.path(path).mkdir()
            return paramiko.SFTP_OK
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def rmdir(self, path):
        try:
            self.path(path).rmdir()
            return paramiko.SFTP_OK
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def chattr(self, path, attrs):
        try:
            if attrs.st_mode is not None:
                os.chmod(self.path(path), attrs.st_mode & 0o7777)
            return paramiko.SFTP_OK
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def symlink(self, target_path, path):
        try:
            link_path = self._raw_path(path)
            if target_path.startswith("/"):
                resolved_target = self.path(target_path)
                rel_target = os.path.relpath(resolved_target, link_path.parent)
                os.symlink(rel_target, link_path)
            else:
                os.symlink(target_path, link_path)
            return paramiko.SFTP_OK
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    def readlink(self, path):
        try:
            return os.readlink(self._raw_path(path))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)


# ---------------------------------------------------------------------------
# Shared HTTP Handler Base
# ---------------------------------------------------------------------------

class FixtureHTTPHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, EOFError, OSError):
            pass

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0:
            return b""
        chunks = []
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _send_bytes(self, status: int, body: bytes = b"", headers: dict[str, str] | None = None, head_only: bool = False):
        self.close_connection = True
        self.send_response(status)
        self.send_header("Connection", "close")
        hdrs = dict(headers or {})
        if status not in (204, 304):
            hdrs.setdefault("Content-Length", str(len(body)))
        for k, v in hdrs.items():
            self.send_header(k, v)
        self.end_headers()
        if not head_only and body and status not in (204, 304):
            offset = 0
            while offset < len(body):
                self.wfile.write(body[offset : offset + 65536])
                offset += 65536
            self.wfile.flush()

    def _send_json(self, status: int, obj: object, headers: dict[str, str] | None = None):
        merged = {"Content-Type": "application/json; charset=utf-8"}
        if headers:
            merged.update(headers)
        self._send_bytes(status, json.dumps(obj).encode("utf-8"), merged)

    def _send_xml(self, status: int, xml_str: str, headers: dict[str, str] | None = None):
        merged = {"Content-Type": "application/xml; charset=utf-8"}
        if headers:
            merged.update(headers)
        self._send_bytes(status, xml_str.encode("utf-8"), merged)

    def _send_file_or_range(self, data: bytes, base_headers: dict[str, str], head_only: bool = False):
        range_hdr = self.headers.get("Range")
        if range_hdr:
            parsed = parse_range_header(range_hdr, len(data))
            if parsed is None:
                self._send_bytes(416, b"", {"Content-Range": f"bytes */{len(data)}"})
                return
            start, end = parsed
            slice_data = data[start : end + 1]
            hdrs = dict(base_headers)
            hdrs["Content-Range"] = f"bytes {start}-{end}/{len(data)}"
            hdrs["Content-Length"] = str(len(slice_data))
            self._send_bytes(206, slice_data, hdrs, head_only=head_only)
            return
        hdrs = dict(base_headers)
        hdrs["Content-Length"] = str(len(data))
        self._send_bytes(200, data, hdrs, head_only=head_only)


# ---------------------------------------------------------------------------
# 1. WebDAV / WebDAVS Fixture Server
# ---------------------------------------------------------------------------

class WebDAVState:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.lock = threading.RLock()

    def resolve_path(self, url_path: str) -> Path:
        decoded = urllib.parse.unquote(url_path)
        norm = posixpath.normpath("/" + decoded).lstrip("/")
        candidate = (self.root / norm).resolve() if norm else self.root
        if candidate != self.root and not candidate.is_relative_to(self.root):
            raise PermissionError("Path escapes WebDAV root")
        return candidate

    def href_for(self, fs_path: Path) -> str:
        rel = fs_path.resolve().relative_to(self.root).as_posix()
        base = "/" if rel == "." else "/" + rel
        if fs_path.is_dir() and not base.endswith("/"):
            base += "/"
        return urllib.parse.quote(base, safe="/")


def make_webdav_handler(state: WebDAVState):
    class WebDAVHandler(FixtureHTTPHandler):
        def _check_auth(self) -> bool:
            expected = base64.b64encode(f"{FIXTURE_USER}:{FIXTURE_PASS}".encode()).decode()
            if self.headers.get("Authorization") != f"Basic {expected}":
                self._send_bytes(401, b"Unauthorized", {"WWW-Authenticate": 'Basic realm="fixture"'})
                return False
            return True

        def _propfind_response(self, fs_path: Path) -> str:
            st = fs_path.stat()
            href = xml_escape(state.href_for(fs_path))
            name = xml_escape("/" if fs_path == state.root else fs_path.name)
            mod = xml_escape(rfc1123(st.st_mtime))
            etag = xml_escape(f'"{int(st.st_mtime_ns)}-{st.st_size}"')
            if fs_path.is_dir():
                prop = (
                    f"<D:displayname>{name}</D:displayname>"
                    f"<D:getlastmodified>{mod}</D:getlastmodified>"
                    f"<D:resourcetype><D:collection/></D:resourcetype>"
                )
            else:
                prop = (
                    f"<D:displayname>{name}</D:displayname>"
                    f"<D:getcontentlength>{st.st_size}</D:getcontentlength>"
                    f"<D:getlastmodified>{mod}</D:getlastmodified>"
                    f"<D:getetag>{etag}</D:getetag>"
                    f"<D:resourcetype/>"
                )
            return f"<D:response><D:href>{href}</D:href><D:propstat><D:prop>{prop}</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"

        def do_PROPFIND(self):
            if not self._check_auth():
                return
            _ = self._read_body()
            depth = (self.headers.get("Depth") or "1").strip()
            parsed = urllib.parse.urlsplit(self.path)
            with state.lock:
                try:
                    target = state.resolve_path(parsed.path)
                except PermissionError:
                    self._send_bytes(403)
                    return
                if not target.exists():
                    self._send_bytes(404)
                    return
                responses = [self._propfind_response(target)]
                if target.is_dir() and depth != "0":
                    for child in sorted(target.iterdir(), key=lambda p: p.name):
                        responses.append(self._propfind_response(child))
            xml = '<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">' + "".join(responses) + "</D:multistatus>"
            self._send_xml(207, xml)

        def do_HEAD(self):
            if not self._check_auth():
                return
            parsed = urllib.parse.urlsplit(self.path)
            with state.lock:
                try:
                    target = state.resolve_path(parsed.path)
                except PermissionError:
                    self._send_bytes(403)
                    return
                if not target.exists() or target.is_dir():
                    self._send_bytes(404)
                    return
                st = target.stat()
                headers = {
                    "Content-Type": "application/octet-stream",
                    "Cache-Control": "no-cache",
                    "ETag": f'"{int(st.st_mtime_ns)}-{st.st_size}"',
                    "Last-Modified": rfc1123(st.st_mtime),
                    "Content-Length": str(st.st_size),
                }
            self._send_bytes(200, b"", headers, head_only=True)

        def do_GET(self):
            if not self._check_auth():
                return
            parsed = urllib.parse.urlsplit(self.path)
            with state.lock:
                try:
                    target = state.resolve_path(parsed.path)
                except PermissionError:
                    self._send_bytes(403)
                    return
                if not target.exists() or target.is_dir():
                    self._send_bytes(404)
                    return
                st = target.stat()
                data = target.read_bytes()
                headers = {
                    "Content-Type": "application/octet-stream",
                    "ETag": f'"{int(st.st_mtime_ns)}-{st.st_size}"',
                    "Last-Modified": rfc1123(st.st_mtime),
                }
            self._send_file_or_range(data, headers)

        def do_PUT(self):
            if not self._check_auth():
                return
            body = self._read_body()
            parsed = urllib.parse.urlsplit(self.path)
            with state.lock:
                try:
                    target = state.resolve_path(parsed.path)
                except PermissionError:
                    self._send_bytes(403)
                    return
                if not target.parent.exists():
                    self._send_bytes(409)
                    return
                existed = target.exists()
                target.write_bytes(body)
            self._send_bytes(204 if existed else 201)

        def do_MKCOL(self):
            if not self._check_auth():
                return
            _ = self._read_body()
            parsed = urllib.parse.urlsplit(self.path)
            with state.lock:
                try:
                    target = state.resolve_path(parsed.path)
                except PermissionError:
                    self._send_bytes(403)
                    return
                if target.exists():
                    self._send_bytes(405)
                    return
                if not target.parent.exists():
                    self._send_bytes(409)
                    return
                target.mkdir()
            self._send_bytes(201)

        def do_MOVE(self):
            if not self._check_auth():
                return
            _ = self._read_body()
            dest = self.headers.get("Destination")
            if not dest:
                self._send_bytes(400)
                return
            src_path = urllib.parse.urlsplit(self.path).path
            dst_path = urllib.parse.urlsplit(dest).path
            with state.lock:
                try:
                    src = state.resolve_path(src_path)
                    dst = state.resolve_path(dst_path)
                except PermissionError:
                    self._send_bytes(403)
                    return
                if not src.exists():
                    self._send_bytes(404)
                    return
                if dst.exists():
                    if dst.is_dir():
                        shutil.rmtree(dst)
                    else:
                        dst.unlink()
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(src), str(dst))
            self._send_bytes(204)

        def do_DELETE(self):
            if not self._check_auth():
                return
            _ = self._read_body()
            parsed = urllib.parse.urlsplit(self.path)
            with state.lock:
                try:
                    target = state.resolve_path(parsed.path)
                except PermissionError:
                    self._send_bytes(403)
                    return
                if not target.exists():
                    self._send_bytes(404)
                    return
                if target.is_dir():
                    shutil.rmtree(target)
                else:
                    target.unlink()
            self._send_bytes(204)

    return WebDAVHandler


# ---------------------------------------------------------------------------
# 2. Amazon S3 Fixture Server (SigV4 + Presigned URL + Multipart + Pagination)
# ---------------------------------------------------------------------------

def aws_uri_encode(val: str, encode_slash: bool) -> str:
    safe = "-._~" if encode_slash else "/-._~"
    return urllib.parse.quote(val, safe=safe)


def derive_aws4_key(secret: str, date_stamp: str, region: str, service: str) -> bytes:
    k_date = hmac.new(("AWS4" + secret).encode("utf-8"), date_stamp.encode("utf-8"), hashlib.sha256).digest()
    k_region = hmac.new(k_date, region.encode("utf-8"), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode("utf-8"), hashlib.sha256).digest()
    return hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()


class S3State:
    def __init__(self, page_limit: int = 2):
        self.lock = threading.RLock()
        self.objects: dict[str, dict] = {}
        self.uploads: dict[str, dict] = {}
        self.page_limit = page_limit

        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        seed = b"fixture content"
        self.objects["中文 seed.txt"] = {
            "data": seed,
            "etag": f'"{hashlib.md5(seed).hexdigest()}"',
            "content_type": "text/plain; charset=utf-8",
            "cache_control": "",
            "storage_class": "STANDARD",
            "acl": "private",
            "meta": {},
            "modified": now,
        }


def make_s3_handler(state: S3State):
    class S3Handler(FixtureHTTPHandler):
        def _resolve_secret(self, access_key: str, session_token: str) -> str | None:
            if access_key == S3_ACCESS_KEY and not session_token:
                return S3_SECRET_KEY
            if access_key == STS_ACCESS_KEY and session_token == STS_SESSION_TOKEN:
                return STS_SECRET_KEY
            return None

        def _verify_sigv4(self, parsed: urllib.parse.SplitResult) -> bool:
            query_pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
            query_dict = dict(query_pairs)
            if "X-Amz-Signature" in query_dict:
                if query_dict.get("X-Amz-Algorithm") != "AWS4-HMAC-SHA256":
                    return False
                cred = query_dict.get("X-Amz-Credential", "")
                amz_date = query_dict.get("X-Amz-Date", "")
                signed_headers_str = query_dict.get("X-Amz-SignedHeaders", "")
                provided_sig = query_dict.get("X-Amz-Signature", "")
                parts = cred.split("/")
                if len(parts) != 5 or parts[2] != S3_REGION or parts[3] != "s3":
                    return False
                secret_key = self._resolve_secret(parts[0], query_dict.get("X-Amz-Security-Token", ""))
                if not secret_key:
                    return False
                date_stamp = parts[1]
                signed_headers = [h.strip().lower() for h in signed_headers_str.split(";") if h.strip()]
                canonical_headers = "".join(f"{h}:{(self.headers.get(h) or '').strip()}\n" for h in signed_headers)
                canon_query_pairs = sorted(
                    (aws_uri_encode(k, True), aws_uri_encode(v, True))
                    for k, v in query_pairs
                    if k != "X-Amz-Signature"
                )
                canonical_query = "&".join(f"{k}={v}" for k, v in canon_query_pairs)
                unquoted_path = urllib.parse.unquote(parsed.path) or "/"
                canonical_uri = aws_uri_encode(unquoted_path, False)
                canonical_req = "\n".join([
                    self.command.upper(),
                    canonical_uri,
                    canonical_query,
                    canonical_headers,
                    signed_headers_str,
                    "UNSIGNED-PAYLOAD",
                ])
                scope = f"{date_stamp}/{S3_REGION}/s3/aws4_request"
                string_to_sign = "\n".join([
                    "AWS4-HMAC-SHA256",
                    amz_date,
                    scope,
                    hashlib.sha256(canonical_req.encode("utf-8")).hexdigest(),
                ])
                expected_sig = hmac.new(
                    derive_aws4_key(secret_key, date_stamp, S3_REGION, "s3"),
                    string_to_sign.encode("utf-8"),
                    hashlib.sha256,
                ).hexdigest()
                return hmac.compare_digest(expected_sig, provided_sig)

            auth = self.headers.get("Authorization") or ""
            if not auth.startswith("AWS4-HMAC-SHA256 "):
                return False
            fields = {}
            for part in auth[len("AWS4-HMAC-SHA256 "):].split(","):
                k, _, v = part.strip().partition("=")
                fields[k.strip()] = v.strip()
            cred_parts = fields.get("Credential", "").split("/")
            if len(cred_parts) != 5 or cred_parts[2] != S3_REGION or cred_parts[3] != "s3":
                return False
            secret_key = self._resolve_secret(cred_parts[0], self.headers.get("X-Amz-Security-Token") or "")
            if not secret_key:
                return False
            date_stamp = cred_parts[1]
            amz_date = self.headers.get("x-amz-date") or ""
            payload_hash = self.headers.get("x-amz-content-sha256") or ""
            signed_headers_str = fields.get("SignedHeaders", "")
            signed_headers = [h.strip().lower() for h in signed_headers_str.split(";") if h.strip()]
            canonical_headers = "".join(f"{h}:{(self.headers.get(h) or '').strip()}\n" for h in signed_headers)
            canon_query_pairs = sorted((aws_uri_encode(k, True), aws_uri_encode(v, True)) for k, v in query_pairs)
            canonical_query = "&".join(f"{k}={v}" for k, v in canon_query_pairs)
            unquoted_path = urllib.parse.unquote(parsed.path) or "/"
            canonical_uri = aws_uri_encode(unquoted_path, False)
            canonical_req = "\n".join([
                self.command.upper(),
                canonical_uri,
                canonical_query,
                canonical_headers,
                signed_headers_str,
                payload_hash,
            ])
            scope = f"{date_stamp}/{S3_REGION}/s3/aws4_request"
            string_to_sign = "\n".join([
                "AWS4-HMAC-SHA256",
                amz_date,
                scope,
                hashlib.sha256(canonical_req.encode("utf-8")).hexdigest(),
            ])
            expected_sig = hmac.new(
                derive_aws4_key(secret_key, date_stamp, S3_REGION, "s3"),
                string_to_sign.encode("utf-8"),
                hashlib.sha256,
            ).hexdigest()
            return hmac.compare_digest(expected_sig, fields.get("Signature", ""))

        def _extract_bucket_key(self, raw_path: str) -> tuple[str, str]:
            decoded = urllib.parse.unquote(raw_path).lstrip("/")
            bucket, _, key = decoded.partition("/")
            return bucket, key

        def _authorize_and_parse(self) -> tuple[urllib.parse.SplitResult, dict[str, str], str, str] | None:
            parsed = urllib.parse.urlsplit(self.path)
            if not self._verify_sigv4(parsed):
                self._send_xml(403, "<Error><Code>SignatureDoesNotMatch</Code></Error>")
                return None
            bucket, key = self._extract_bucket_key(parsed.path)
            if bucket != S3_BUCKET:
                self._send_xml(404, "<Error><Code>NoSuchBucket</Code></Error>")
                return None
            q = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
            return parsed, q, bucket, key

        def do_GET(self):
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path == "/":
                if not self._verify_sigv4(parsed):
                    self._send_xml(403, "<Error><Code>SignatureDoesNotMatch</Code></Error>")
                    return
                q = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
                if "list-type" not in q:
                    created = iso8601_z(1735689600)
                    xml = (
                        '<?xml version="1.0" encoding="UTF-8"?>'
                        '<ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                        "<Owner><ID>fixture-owner</ID><DisplayName>fixture</DisplayName></Owner>"
                        "<Buckets>"
                        f"<Bucket><Name>{S3_BUCKET}</Name><CreationDate>{created}</CreationDate></Bucket>"
                        f"<Bucket><Name>archive-bucket</Name><CreationDate>{created}</CreationDate></Bucket>"
                        "</Buckets>"
                        "</ListAllMyBucketsResult>"
                    )
                    self._send_xml(200, xml)
                    return

            ctx = self._authorize_and_parse()
            if not ctx:
                return
            _, q, _, key = ctx

            if "list-type" in q and key == "":
                prefix = q.get("prefix", "")
                delimiter = q.get("delimiter", "")
                cont = q.get("continuation-token", "")
                start_idx = int(cont.split(":", 1)[1]) if cont.startswith("page:") else 0
                with state.lock:
                    items: list[tuple[str, object]] = []
                    seen_prefixes: set[str] = set()
                    for k in sorted(state.objects.keys()):
                        if not k.startswith(prefix):
                            continue
                        if delimiter and k == prefix:
                            continue
                        rel = k[len(prefix):]
                        if delimiter and delimiter in rel:
                            sub = prefix + rel.split(delimiter, 1)[0] + delimiter
                            if sub not in seen_prefixes:
                                seen_prefixes.add(sub)
                                items.append(("prefix", sub))
                        else:
                            items.append(("object", (k, state.objects[k])))
                page = items[start_idx : start_idx + state.page_limit]
                is_truncated = (start_idx + state.page_limit) < len(items)
                next_tok = f"page:{start_idx + state.page_limit}" if is_truncated else ""
                body_parts = [
                    '<?xml version="1.0" encoding="UTF-8"?>',
                    "<ListBucketResult>",
                    f"<Name>{S3_BUCKET}</Name>",
                    f"<Prefix>{xml_escape(prefix)}</Prefix>",
                    f"<IsTruncated>{'true' if is_truncated else 'false'}</IsTruncated>",
                ]
                if next_tok:
                    body_parts.append(f"<NextContinuationToken>{xml_escape(next_tok)}</NextContinuationToken>")
                for kind, val in page:
                    if kind == "prefix":
                        body_parts.append(f"<CommonPrefixes><Prefix>{xml_escape(val)}</Prefix></CommonPrefixes>")
                    else:
                        obj_key, meta = val
                        body_parts.append(
                            f"<Contents><Key>{xml_escape(obj_key)}</Key>"
                            f"<LastModified>{iso8601_z(meta['modified'])}</LastModified>"
                            f"<ETag>{xml_escape(meta['etag'])}</ETag>"
                            f"<Size>{len(meta['data'])}</Size></Contents>"
                        )
                body_parts.append("</ListBucketResult>")
                self._send_xml(200, "".join(body_parts))
                return

            with state.lock:
                obj = state.objects.get(key)
                if not obj:
                    self._send_xml(404, "<Error><Code>NoSuchKey</Code></Error>")
                    return
                data = obj["data"]
                headers = {
                    "Content-Type": obj["content_type"] or "application/octet-stream",
                    "ETag": obj["etag"],
                    "Last-Modified": rfc1123(obj["modified"]),
                }
            self._send_file_or_range(data, headers)

        def do_HEAD(self):
            ctx = self._authorize_and_parse()
            if not ctx:
                return
            _, _, _, key = ctx
            with state.lock:
                obj = state.objects.get(key)
                if not obj:
                    self._send_bytes(404, b"", head_only=True)
                    return
                headers = {
                    "Content-Type": obj["content_type"] or "application/octet-stream",
                    "ETag": obj["etag"],
                    "Last-Modified": rfc1123(obj["modified"]),
                    "Content-Length": str(len(obj["data"])),
                    "x-amz-storage-class": obj["storage_class"],
                    "x-amz-acl": obj["acl"],
                }
                if obj["cache_control"]:
                    headers["Cache-Control"] = obj["cache_control"]
                for mk, mv in obj["meta"].items():
                    headers[f"x-amz-meta-{mk}"] = mv
            self._send_bytes(200, b"", headers, head_only=True)

        def do_POST(self):
            ctx = self._authorize_and_parse()
            if not ctx:
                return
            _, q, _, key = ctx
            body = self._read_body()

            if "delete" in q and key == "":
                root_el = ET.fromstring(body)
                deleted = []
                with state.lock:
                    for obj_el in root_el.findall(".//Object"):
                        k_el = obj_el.find("Key")
                        if k_el is not None and k_el.text:
                            state.objects.pop(k_el.text, None)
                            deleted.append(f"<Deleted><Key>{xml_escape(k_el.text)}</Key></Deleted>")
                self._send_xml(200, f'<?xml version="1.0" encoding="UTF-8"?><DeleteResult>{"".join(deleted)}</DeleteResult>')
                return

            if "uploads" in q:
                upload_id = uuid.uuid4().hex
                with state.lock:
                    state.uploads[upload_id] = {
                        "key": key,
                        "parts": {},
                        "storage_class": self.headers.get("x-amz-storage-class") or "STANDARD",
                    }
                self._send_xml(
                    200,
                    f'<?xml version="1.0" encoding="UTF-8"?>'
                    f"<InitiateMultipartUploadResult><Bucket>{S3_BUCKET}</Bucket>"
                    f"<Key>{xml_escape(key)}</Key><UploadId>{upload_id}</UploadId></InitiateMultipartUploadResult>",
                )
                return

            if "uploadId" in q:
                upload_id = q["uploadId"]
                root_el = ET.fromstring(body)
                with state.lock:
                    up = state.uploads.get(upload_id)
                    if not up or up["key"] != key:
                        self._send_xml(404, "<Error><Code>NoSuchUpload</Code></Error>")
                        return
                    assembled = bytearray()
                    for part_el in root_el.findall(".//Part"):
                        pnum = int(part_el.findtext("PartNumber") or "0")
                        etag = (part_el.findtext("ETag") or "").strip()
                        stored = up["parts"].get(pnum)
                        if not stored or stored[1] != etag:
                            self._send_xml(400, "<Error><Code>InvalidPart</Code></Error>")
                            return
                        assembled.extend(stored[0])
                    data = bytes(assembled)
                    final_etag = f'"{hashlib.md5(data).hexdigest()}-{len(up["parts"])}"'
                    state.objects[key] = {
                        "data": data,
                        "etag": final_etag,
                        "content_type": "application/octet-stream",
                        "cache_control": "",
                        "storage_class": up["storage_class"],
                        "acl": "private",
                        "meta": {},
                        "modified": datetime.datetime.now(datetime.timezone.utc).timestamp(),
                    }
                    del state.uploads[upload_id]
                self._send_xml(
                    200,
                    f'<?xml version="1.0" encoding="UTF-8"?><CompleteMultipartUploadResult>'
                    f"<Bucket>{S3_BUCKET}</Bucket><Key>{xml_escape(key)}</Key><ETag>{xml_escape(final_etag)}</ETag>"
                    f"</CompleteMultipartUploadResult>",
                )
                return

            self._send_xml(400, "<Error><Code>InvalidRequest</Code></Error>")

        def do_PUT(self):
            ctx = self._authorize_and_parse()
            if not ctx:
                return
            _, q, _, key = ctx
            body = self._read_body()

            if "uploadId" in q and "partNumber" in q:
                upload_id = q["uploadId"]
                part_num = int(q["partNumber"])
                expected_sha = self.headers.get("x-amz-content-sha256") or ""
                if expected_sha and expected_sha != "UNSIGNED-PAYLOAD" and hashlib.sha256(body).hexdigest() != expected_sha:
                    self._send_xml(400, "<Error><Code>XAmzContentSHA256Mismatch</Code></Error>")
                    return
                etag = f'"{hashlib.md5(body).hexdigest()}"'
                with state.lock:
                    up = state.uploads.get(upload_id)
                    if not up or up["key"] != key:
                        self._send_xml(404, "<Error><Code>NoSuchUpload</Code></Error>")
                        return
                    up["parts"][part_num] = (body, etag)
                self._send_bytes(200, b"", {"ETag": etag})
                return

            copy_source = self.headers.get("x-amz-copy-source")
            if copy_source is not None:
                decoded_src = urllib.parse.unquote(copy_source).lstrip("/")
                src_bucket, _, src_key = decoded_src.partition("/")
                with state.lock:
                    src_obj = state.objects.get(src_key) if src_bucket == S3_BUCKET else None
                    if not src_obj:
                        self._send_xml(404, "<Error><Code>NoSuchKey</Code></Error>")
                        return
                    directive = (self.headers.get("x-amz-metadata-directive") or "COPY").upper()
                    if directive == "REPLACE":
                        meta = {
                            k[len("x-amz-meta-"):].lower(): v
                            for k, v in self.headers.items()
                            if k.lower().startswith("x-amz-meta-")
                        }
                        new_obj = {
                            "data": src_obj["data"],
                            "etag": src_obj["etag"],
                            "content_type": self.headers.get("Content-Type") or src_obj["content_type"],
                            "cache_control": self.headers.get("Cache-Control") or "",
                            "storage_class": self.headers.get("x-amz-storage-class") or src_obj["storage_class"],
                            "acl": self.headers.get("x-amz-acl") or src_obj["acl"],
                            "meta": meta,
                            "modified": datetime.datetime.now(datetime.timezone.utc).timestamp(),
                        }
                    else:
                        new_obj = dict(src_obj)
                        new_obj["meta"] = dict(src_obj["meta"])
                        new_obj["modified"] = datetime.datetime.now(datetime.timezone.utc).timestamp()
                    state.objects[key] = new_obj
                self._send_xml(200, f"<CopyObjectResult><ETag>{xml_escape(new_obj['etag'])}</ETag></CopyObjectResult>")
                return

            expected_sha = self.headers.get("x-amz-content-sha256") or ""
            if expected_sha and expected_sha != "UNSIGNED-PAYLOAD" and hashlib.sha256(body).hexdigest() != expected_sha:
                self._send_xml(400, "<Error><Code>XAmzContentSHA256Mismatch</Code></Error>")
                return

            etag = f'"{hashlib.md5(body).hexdigest()}"'
            meta = {
                k[len("x-amz-meta-"):].lower(): v
                for k, v in self.headers.items()
                if k.lower().startswith("x-amz-meta-")
            }
            with state.lock:
                state.objects[key] = {
                    "data": body,
                    "etag": etag,
                    "content_type": self.headers.get("Content-Type") or "application/octet-stream",
                    "cache_control": self.headers.get("Cache-Control") or "",
                    "storage_class": self.headers.get("x-amz-storage-class") or "STANDARD",
                    "acl": self.headers.get("x-amz-acl") or "private",
                    "meta": meta,
                    "modified": datetime.datetime.now(datetime.timezone.utc).timestamp(),
                }
            self._send_bytes(200, b"", {"ETag": etag})

        def do_DELETE(self):
            ctx = self._authorize_and_parse()
            if not ctx:
                return
            _, q, _, key = ctx
            _ = self._read_body()
            if "uploadId" in q:
                with state.lock:
                    state.uploads.pop(q["uploadId"], None)
                self._send_bytes(204)
                return
            with state.lock:
                state.objects.pop(key, None)
            self._send_bytes(204)

    return S3Handler


# ---------------------------------------------------------------------------
# 2b. AWS STS Fixture Server (SigV4 AssumeRole)
# ---------------------------------------------------------------------------

def make_sts_handler():
    class STSHandler(FixtureHTTPHandler):
        def _verify_sts_sigv4(self, parsed: urllib.parse.SplitResult, body: bytes) -> bool:
            auth = self.headers.get("Authorization") or ""
            if not auth.startswith("AWS4-HMAC-SHA256 "):
                return False
            fields = {}
            for part in auth[len("AWS4-HMAC-SHA256 "):].split(","):
                k, _, v = part.strip().partition("=")
                fields[k.strip()] = v.strip()
            cred_parts = fields.get("Credential", "").split("/")
            if len(cred_parts) != 5 or cred_parts[0] != S3_ACCESS_KEY or cred_parts[2] != S3_REGION or cred_parts[3] != "sts":
                return False
            date_stamp = cred_parts[1]
            amz_date = self.headers.get("x-amz-date") or ""
            payload_hash = self.headers.get("x-amz-content-sha256") or ""
            if payload_hash != hashlib.sha256(body).hexdigest():
                return False
            signed_headers_str = fields.get("SignedHeaders", "")
            signed_headers = [h.strip().lower() for h in signed_headers_str.split(";") if h.strip()]
            canonical_headers = "".join(f"{h}:{(self.headers.get(h) or '').strip()}\n" for h in signed_headers)
            query_pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
            canon_query_pairs = sorted((aws_uri_encode(k, True), aws_uri_encode(v, True)) for k, v in query_pairs)
            canonical_query = "&".join(f"{k}={v}" for k, v in canon_query_pairs)
            unquoted_path = urllib.parse.unquote(parsed.path) or "/"
            canonical_uri = aws_uri_encode(unquoted_path, False)
            canonical_req = "\n".join([
                self.command.upper(),
                canonical_uri,
                canonical_query,
                canonical_headers,
                signed_headers_str,
                payload_hash,
            ])
            scope = f"{date_stamp}/{S3_REGION}/sts/aws4_request"
            string_to_sign = "\n".join([
                "AWS4-HMAC-SHA256",
                amz_date,
                scope,
                hashlib.sha256(canonical_req.encode("utf-8")).hexdigest(),
            ])
            expected_sig = hmac.new(
                derive_aws4_key(S3_SECRET_KEY, date_stamp, S3_REGION, "sts"),
                string_to_sign.encode("utf-8"),
                hashlib.sha256,
            ).hexdigest()
            return hmac.compare_digest(expected_sig, fields.get("Signature", ""))

        def do_POST(self):
            parsed = urllib.parse.urlsplit(self.path)
            body = self._read_body()
            if not self._verify_sts_sigv4(parsed, body):
                self._send_xml(403, "<ErrorResponse><Error><Code>SignatureDoesNotMatch</Code></Error></ErrorResponse>")
                return
            form = urllib.parse.parse_qs(body.decode("utf-8"), keep_blank_values=True)
            if form.get("Action") != ["AssumeRole"] or form.get("RoleArn") != [STS_ROLE_ARN]:
                self._send_xml(400, "<ErrorResponse><Error><Code>ValidationError</Code></Error></ErrorResponse>")
                return
            expiration = iso8601_z(datetime.datetime.now(datetime.timezone.utc).timestamp() + 3600)
            xml = (
                '<?xml version="1.0" encoding="UTF-8"?>'
                '<AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">'
                "<AssumeRoleResult>"
                "<Credentials>"
                f"<AccessKeyId>{STS_ACCESS_KEY}</AccessKeyId>"
                f"<SecretAccessKey>{STS_SECRET_KEY}</SecretAccessKey>"
                f"<SessionToken>{STS_SESSION_TOKEN}</SessionToken>"
                f"<Expiration>{expiration}</Expiration>"
                "</Credentials>"
                "</AssumeRoleResult>"
                "</AssumeRoleResponse>"
            )
            self._send_xml(200, xml)

    return STSHandler


# ---------------------------------------------------------------------------
# 3. Backblaze B2 Fixture Server
# ---------------------------------------------------------------------------

class B2State:
    def __init__(self, port_holder: list[int], page_limit: int = 2):
        self.lock = threading.RLock()
        self.port_holder = port_holder
        self.page_limit = page_limit
        self.auth_token = "b2-auth-fixture-token"
        self.upload_token = "b2-upload-fixture-token"
        self.dl_tokens: set[str] = set()
        self.files: dict[str, dict] = {}
        self.large_files: dict[str, dict] = {}

        seed = b"fixture content"
        self._store_file("中文 seed.txt", seed, "text/plain; charset=utf-8", {"origin": "seed"})

    def _store_file(self, name: str, data: bytes, content_type: str = "application/octet-stream", info: dict[str, str] | None = None) -> dict:
        fid = f"4_z{B2_BUCKET_ID}_{uuid.uuid4().hex[:12]}"
        item = {
            "fileId": fid,
            "fileName": name,
            "data": data,
            "sha1": hashlib.sha1(data).hexdigest(),
            "contentLength": len(data),
            "uploadTimestamp": int(datetime.datetime.now(datetime.timezone.utc).timestamp() * 1000),
            "contentType": content_type,
            "info": dict(info or {}),
        }
        self.files[name] = item
        return item


def make_b2_handler(state: B2State):
    class B2Handler(FixtureHTTPHandler):
        def _require_auth(self) -> bool:
            if self.headers.get("Authorization") != state.auth_token:
                self._send_json(401, {"code": "bad_auth_token", "message": "Invalid auth token", "status": 401})
                return False
            return True

        def do_GET(self):
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path == "/b2api/v2/b2_authorize_account":
                expected = base64.b64encode(f"{B2_KEY_ID}:{B2_APP_KEY}".encode()).decode()
                if self.headers.get("Authorization") != f"Basic {expected}":
                    self._send_json(401, {"code": "unauthorized", "status": 401})
                    return
                port = state.port_holder[0]
                self._send_json(200, {
                    "accountId": B2_ACCOUNT_ID,
                    "authorizationToken": state.auth_token,
                    "apiUrl": f"https://127.0.0.1:{port}",
                    "downloadUrl": f"https://127.0.0.1:{port}",
                    "allowed": {"bucketId": B2_BUCKET_ID, "bucketName": B2_BUCKET_NAME},
                })
                return

            if parsed.path.startswith("/file/"):
                q = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
                tok = self.headers.get("Authorization") or q.get("Authorization") or ""
                if tok != state.auth_token and tok not in state.dl_tokens:
                    self._send_json(401, {"code": "unauthorized", "status": 401})
                    return
                rest = urllib.parse.unquote(parsed.path[len("/file/"):])
                bkt, _, key = rest.partition("/")
                if bkt != B2_BUCKET_NAME:
                    self._send_json(404, {"code": "not_found", "status": 404})
                    return
                with state.lock:
                    item = state.files.get(key)
                    if not item:
                        self._send_json(404, {"code": "not_found", "status": 404})
                        return
                    data = item["data"]
                    headers = {
                        "Content-Type": item["contentType"],
                        "X-Bz-File-Id": item["fileId"],
                        "X-Bz-Content-Sha1": item["sha1"],
                        "X-Bz-Upload-Timestamp": str(item["uploadTimestamp"]),
                        "Last-Modified": rfc1123(item["uploadTimestamp"] / 1000.0),
                    }
                    for ik, iv in item["info"].items():
                        headers[f"X-Bz-Info-{ik}"] = iv
                self._send_file_or_range(data, headers)
                return

            self._send_json(404, {"code": "not_found", "status": 404})

        def do_HEAD(self):
            parsed = urllib.parse.urlsplit(self.path)
            if not parsed.path.startswith("/file/"):
                self._send_bytes(404, b"", head_only=True)
                return
            if self.headers.get("Authorization") != state.auth_token:
                self._send_bytes(401, b"", head_only=True)
                return
            rest = urllib.parse.unquote(parsed.path[len("/file/"):])
            bkt, _, key = rest.partition("/")
            if bkt != B2_BUCKET_NAME:
                self._send_bytes(404, b"", head_only=True)
                return
            with state.lock:
                item = state.files.get(key)
                if not item:
                    self._send_bytes(404, b"", head_only=True)
                    return
                headers = {
                    "Content-Type": item["contentType"],
                    "Content-Length": str(item["contentLength"]),
                    "X-Bz-File-Id": item["fileId"],
                    "X-Bz-Content-Sha1": item["sha1"],
                    "X-Bz-Upload-Timestamp": str(item["uploadTimestamp"]),
                    "Last-Modified": rfc1123(item["uploadTimestamp"] / 1000.0),
                }
                for ik, iv in item["info"].items():
                    headers[f"X-Bz-Info-{ik}"] = iv
            self._send_bytes(200, b"", headers, head_only=True)

        def do_POST(self):
            parsed = urllib.parse.urlsplit(self.path)
            body = self._read_body()

            if parsed.path == "/b2api/v2/b2_upload":
                if self.headers.get("Authorization") != state.upload_token:
                    self._send_json(401, {"code": "bad_auth_token", "status": 401})
                    return
                file_name = urllib.parse.unquote(self.headers.get("X-Bz-File-Name") or "")
                expected_sha1 = (self.headers.get("X-Bz-Content-Sha1") or "").lower()
                actual_sha1 = hashlib.sha1(body).hexdigest()
                if not file_name or actual_sha1 != expected_sha1:
                    self._send_json(400, {"code": "bad_sha1", "status": 400})
                    return
                ctype = self.headers.get("Content-Type") or "application/octet-stream"
                if ctype == "b2/x-auto":
                    ctype = "application/octet-stream"
                info = {
                    k[len("X-Bz-Info-"):].lower(): v
                    for k, v in self.headers.items()
                    if k.lower().startswith("x-bz-info-")
                }
                with state.lock:
                    item = state._store_file(file_name, body, ctype, info)
                self._send_json(200, {
                    "fileId": item["fileId"],
                    "fileName": item["fileName"],
                    "contentLength": item["contentLength"],
                    "contentSha1": item["sha1"],
                    "uploadTimestamp": item["uploadTimestamp"],
                    "action": "upload",
                    "contentType": item["contentType"],
                })
                return

            if parsed.path.startswith("/b2api/v2/b2_upload_part/"):
                if not self._require_auth():
                    return
                file_id = parsed.path[len("/b2api/v2/b2_upload_part/"):]
                part_num = int(self.headers.get("X-Bz-Part-Number") or "0")
                expected_sha1 = (self.headers.get("X-Bz-Content-Sha1") or "").lower()
                actual_sha1 = hashlib.sha1(body).hexdigest()
                if actual_sha1 != expected_sha1 or part_num <= 0:
                    self._send_json(400, {"code": "bad_part", "status": 400})
                    return
                with state.lock:
                    lf = state.large_files.get(file_id)
                    if not lf:
                        self._send_json(404, {"code": "not_found", "status": 404})
                        return
                    lf["parts"][part_num] = (body, actual_sha1)
                self._send_json(200, {"fileId": file_id, "partNumber": part_num, "contentSha1": actual_sha1})
                return

            if not self._require_auth():
                return
            payload = json.loads(body.decode("utf-8")) if body else {}

            if parsed.path == "/b2api/v2/b2_list_buckets":
                self._send_json(200, {"buckets": [{"bucketId": B2_BUCKET_ID, "bucketName": B2_BUCKET_NAME}]})
                return

            if parsed.path == "/b2api/v2/b2_get_upload_url":
                port = state.port_holder[0]
                self._send_json(200, {
                    "bucketId": B2_BUCKET_ID,
                    "uploadUrl": f"https://127.0.0.1:{port}/b2api/v2/b2_upload",
                    "authorizationToken": state.upload_token,
                })
                return

            if parsed.path == "/b2api/v2/b2_list_file_names":
                prefix = payload.get("prefix", "")
                delimiter = payload.get("delimiter", "")
                start_name = payload.get("startFileName") or ""
                with state.lock:
                    entries: list[dict] = []
                    seen_folders: set[str] = set()
                    for fname in sorted(state.files.keys()):
                        if not fname.startswith(prefix):
                            continue
                        if delimiter and fname == prefix:
                            continue
                        rel = fname[len(prefix):]
                        if delimiter and delimiter in rel:
                            folder = prefix + rel.split(delimiter, 1)[0] + delimiter
                            if folder not in seen_folders:
                                seen_folders.add(folder)
                                entries.append({"fileId": None, "fileName": folder, "action": "folder"})
                        else:
                            it = state.files[fname]
                            entries.append({
                                "fileId": it["fileId"],
                                "fileName": it["fileName"],
                                "contentLength": it["contentLength"],
                                "uploadTimestamp": it["uploadTimestamp"],
                                "action": "upload",
                                "contentType": it["contentType"],
                            })
                    entries.sort(key=lambda e: e["fileName"])
                    if start_name:
                        entries = [e for e in entries if e["fileName"] >= start_name]
                    page = entries[: state.page_limit]
                    next_name = entries[state.page_limit]["fileName"] if len(entries) > state.page_limit else None
                self._send_json(200, {"files": page, "nextFileName": next_name})
                return

            if parsed.path == "/b2api/v2/b2_start_large_file":
                file_id = f"4_z{B2_BUCKET_ID}_large_{uuid.uuid4().hex[:10]}"
                with state.lock:
                    state.large_files[file_id] = {
                        "fileName": payload["fileName"],
                        "contentType": payload.get("contentType") or "application/octet-stream",
                        "parts": {},
                    }
                self._send_json(200, {"fileId": file_id, "fileName": payload["fileName"]})
                return

            if parsed.path == "/b2api/v2/b2_get_upload_part_url":
                port = state.port_holder[0]
                file_id = payload["fileId"]
                self._send_json(200, {
                    "fileId": file_id,
                    "uploadUrl": f"https://127.0.0.1:{port}/b2api/v2/b2_upload_part/{file_id}",
                    "authorizationToken": state.auth_token,
                })
                return

            if parsed.path == "/b2api/v2/b2_finish_large_file":
                file_id = payload["fileId"]
                expected_sha1s = payload["partSha1Array"]
                with state.lock:
                    lf = state.large_files.pop(file_id, None)
                    if not lf:
                        self._send_json(404, {"code": "not_found", "status": 404})
                        return
                    buf = bytearray()
                    for idx, exp_sha in enumerate(expected_sha1s, start=1):
                        part = lf["parts"].get(idx)
                        if not part or part[1] != exp_sha:
                            self._send_json(400, {"code": "invalid_part", "status": 400})
                            return
                        buf.extend(part[0])
                    item = state._store_file(lf["fileName"], bytes(buf), lf["contentType"])
                self._send_json(200, {
                    "fileId": item["fileId"],
                    "fileName": item["fileName"],
                    "contentLength": item["contentLength"],
                    "uploadTimestamp": item["uploadTimestamp"],
                    "action": "upload",
                    "contentType": item["contentType"],
                })
                return

            if parsed.path == "/b2api/v2/b2_cancel_large_file":
                file_id = payload["fileId"]
                with state.lock:
                    state.large_files.pop(file_id, None)
                self._send_json(200, {"fileId": file_id})
                return

            if parsed.path == "/b2api/v2/b2_copy_file":
                src_id = payload["sourceFileId"]
                dst_name = payload["fileName"]
                with state.lock:
                    src_item = next((v for v in state.files.values() if v["fileId"] == src_id), None)
                    if not src_item:
                        self._send_json(404, {"code": "not_found", "status": 404})
                        return
                    new_item = state._store_file(dst_name, src_item["data"], src_item["contentType"], src_item["info"])
                self._send_json(200, {
                    "fileId": new_item["fileId"],
                    "fileName": new_item["fileName"],
                    "contentLength": new_item["contentLength"],
                    "uploadTimestamp": new_item["uploadTimestamp"],
                    "action": "upload",
                    "contentType": new_item["contentType"],
                })
                return

            if parsed.path == "/b2api/v2/b2_delete_file_version":
                fname = payload["fileName"]
                fid = payload["fileId"]
                with state.lock:
                    cur = state.files.get(fname)
                    if not cur or cur["fileId"] != fid:
                        self._send_json(404, {"code": "file_not_present", "status": 404})
                        return
                    del state.files[fname]
                self._send_json(200, {"fileId": fid, "fileName": fname})
                return

            if parsed.path == "/b2api/v2/b2_get_download_authorization":
                tok = f"b2-dl-{uuid.uuid4().hex}"
                with state.lock:
                    state.dl_tokens.add(tok)
                self._send_json(200, {"authorizationToken": tok})
                return

            self._send_json(404, {"code": "not_found", "status": 404})

    return B2Handler


# ---------------------------------------------------------------------------
# 4. Microsoft Azure Blob Fixture Server (SharedKey + SAS + Pagination)
# ---------------------------------------------------------------------------

class AzureState:
    def __init__(self, page_limit: int = 2):
        self.lock = threading.RLock()
        self.page_limit = page_limit
        self.blobs: dict[str, dict] = {}
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        seed = b"fixture content"
        self.blobs["中文 seed.txt"] = {
            "data": seed,
            "content_type": "text/plain; charset=utf-8",
            "cache_control": "",
            "access_tier": "Hot",
            "etag": f'"0x{hashlib.md5(seed).hexdigest()[:12]}"',
            "meta": {},
            "modified": now,
        }


def make_azure_handler(state: AzureState):
    class AzureHandler(FixtureHTTPHandler):
        def _verify_auth(self, parsed: urllib.parse.SplitResult) -> bool:
            q_pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
            q_dict = dict(q_pairs)
            if "sig" in q_dict:
                # Verify SAS download signature generated by AzureBlobClient.presignedDownloadURL
                canonical_res = f"/blob/{AZURE_ACCOUNT}{urllib.parse.unquote(parsed.path)}"
                string_to_sign = "\n".join([
                    q_dict.get("sp", ""),
                    q_dict.get("st", ""),
                    q_dict.get("se", ""),
                    canonical_res,
                    "",
                    "",
                    q_dict.get("spr", ""),
                    q_dict.get("sv", ""),
                    q_dict.get("sr", ""),
                    "",
                    "",
                    "", "", "", "", "",
                ])
                expected_sig = base64.b64encode(
                    hmac.new(AZURE_SHARED_KEY_BYTES, string_to_sign.encode("utf-8"), hashlib.sha256).digest()
                ).decode("ascii")
                return hmac.compare_digest(expected_sig, q_dict["sig"])

            auth = self.headers.get("Authorization") or ""
            prefix = f"SharedKey {AZURE_ACCOUNT}:"
            if not auth.startswith(prefix):
                return False
            provided_sig = auth[len(prefix):]

            def h(name: str) -> str:
                return self.headers.get(name) or ""

            cl = h("Content-Length")
            cl_canon = "" if (not cl or cl == "0") else cl
            xms = sorted(
                (k.lower(), v.strip())
                for k, v in self.headers.items()
                if k.lower().startswith("x-ms-")
            )
            xms_block = "".join(f"{k}:{v}\n" for k, v in xms)
            canon_res = f"/{AZURE_ACCOUNT}{parsed.path}"
            if q_pairs:
                grouped: dict[str, list[str]] = {}
                for k, v in q_pairs:
                    grouped.setdefault(k.lower(), []).append(v)
                for k in sorted(grouped.keys()):
                    canon_res += f"\n{k}:{','.join(sorted(grouped[k]))}"

            string_to_sign = "\n".join([
                self.command.upper(),
                h("Content-Encoding"),
                h("Content-Language"),
                cl_canon,
                h("Content-MD5"),
                h("Content-Type"),
                "",
                h("If-Modified-Since"),
                h("If-Match"),
                h("If-None-Match"),
                h("If-Unmodified-Since"),
                h("Range"),
                xms_block + canon_res,
            ])
            expected_sig = base64.b64encode(
                hmac.new(AZURE_SHARED_KEY_BYTES, string_to_sign.encode("utf-8"), hashlib.sha256).digest()
            ).decode("ascii")
            return hmac.compare_digest(expected_sig, provided_sig)

        def _parse_container_blob(self, raw_path: str) -> tuple[str, str]:
            decoded = urllib.parse.unquote(raw_path).lstrip("/")
            cont, _, blob = decoded.partition("/")
            return cont, blob

        def _authorize(self) -> tuple[urllib.parse.SplitResult, dict[str, str], str] | None:
            parsed = urllib.parse.urlsplit(self.path)
            if not self._verify_auth(parsed):
                self._send_xml(403, "<Error><Code>AuthenticationFailed</Code></Error>")
                return None
            cont, blob = self._parse_container_blob(parsed.path)
            if cont != AZURE_CONTAINER:
                self._send_xml(404, "<Error><Code>ContainerNotFound</Code></Error>")
                return None
            q = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
            return parsed, q, blob

        def do_GET(self):
            ctx = self._authorize()
            if not ctx:
                return
            _, q, blob = ctx

            if q.get("restype") == "container" and q.get("comp") == "list" and blob == "":
                prefix = q.get("prefix", "")
                delimiter = q.get("delimiter", "")
                marker = q.get("marker", "")
                start_idx = int(marker.split(":", 1)[1]) if marker.startswith("m:") else 0
                with state.lock:
                    items: list[tuple[str, object]] = []
                    seen_prefixes: set[str] = set()
                    for bname in sorted(state.blobs.keys()):
                        if not bname.startswith(prefix):
                            continue
                        if delimiter and bname == prefix:
                            continue
                        rel = bname[len(prefix):]
                        if delimiter and delimiter in rel:
                            sub = prefix + rel.split(delimiter, 1)[0] + delimiter
                            if sub not in seen_prefixes:
                                seen_prefixes.add(sub)
                                items.append(("prefix", sub))
                        else:
                            items.append(("blob", (bname, state.blobs[bname])))
                page = items[start_idx : start_idx + state.page_limit]
                next_marker = f"m:{start_idx + state.page_limit}" if (start_idx + state.page_limit) < len(items) else ""
                parts = ['<?xml version="1.0" encoding="utf-8"?><EnumerationResults><Blobs>']
                for kind, val in page:
                    if kind == "prefix":
                        parts.append(f"<BlobPrefix><Name>{xml_escape(val)}</Name></BlobPrefix>")
                    else:
                        bname, meta = val
                        parts.append(
                            f"<Blob><Name>{xml_escape(bname)}</Name><Properties>"
                            f"<Content-Length>{len(meta['data'])}</Content-Length>"
                            f"<Last-Modified>{rfc1123(meta['modified'])}</Last-Modified>"
                            f"<Content-Type>{xml_escape(meta['content_type'])}</Content-Type>"
                            f"<Etag>{xml_escape(meta['etag'])}</Etag>"
                            f"</Properties></Blob>"
                        )
                parts.append("</Blobs>")
                parts.append(f"<NextMarker>{xml_escape(next_marker)}</NextMarker>" if next_marker else "<NextMarker />")
                parts.append("</EnumerationResults>")
                self._send_xml(200, "".join(parts))
                return

            with state.lock:
                item = state.blobs.get(blob)
                if not item:
                    self._send_xml(404, "<Error><Code>BlobNotFound</Code></Error>")
                    return
                data = item["data"]
                headers = {
                    "Content-Type": item["content_type"],
                    "ETag": item["etag"],
                    "Last-Modified": rfc1123(item["modified"]),
                }
            self._send_file_or_range(data, headers)

        def do_HEAD(self):
            ctx = self._authorize()
            if not ctx:
                return
            _, _, blob = ctx
            with state.lock:
                item = state.blobs.get(blob)
                if not item:
                    self._send_bytes(404, b"", head_only=True)
                    return
                headers = {
                    "Content-Type": item["content_type"],
                    "Content-Length": str(len(item["data"])),
                    "ETag": item["etag"],
                    "Last-Modified": rfc1123(item["modified"]),
                    "x-ms-access-tier": item["access_tier"],
                }
                if item["cache_control"]:
                    headers["Cache-Control"] = item["cache_control"]
                for mk, mv in item["meta"].items():
                    headers[f"x-ms-meta-{mk}"] = mv
            self._send_bytes(200, b"", headers, head_only=True)

        def do_PUT(self):
            ctx = self._authorize()
            if not ctx:
                return
            _, q, blob = ctx
            body = self._read_body()
            comp = q.get("comp", "")

            if comp == "metadata":
                with state.lock:
                    item = state.blobs.get(blob)
                    if not item:
                        self._send_xml(404, "<Error><Code>BlobNotFound</Code></Error>")
                        return
                    item["meta"] = {
                        k[len("x-ms-meta-"):].lower(): v
                        for k, v in self.headers.items()
                        if k.lower().startswith("x-ms-meta-")
                    }
                    item["modified"] = datetime.datetime.now(datetime.timezone.utc).timestamp()
                self._send_bytes(200)
                return

            if comp == "properties":
                with state.lock:
                    item = state.blobs.get(blob)
                    if not item:
                        self._send_xml(404, "<Error><Code>BlobNotFound</Code></Error>")
                        return
                    if ct := self.headers.get("x-ms-blob-content-type"):
                        item["content_type"] = ct
                    if cc := self.headers.get("x-ms-blob-cache-control"):
                        item["cache_control"] = cc
                self._send_bytes(200)
                return

            copy_src = self.headers.get("x-ms-copy-source")
            if copy_src is not None:
                src_cont, src_blob = self._parse_container_blob(urllib.parse.urlsplit(copy_src).path)
                with state.lock:
                    src_item = state.blobs.get(src_blob) if src_cont == AZURE_CONTAINER else None
                    if not src_item:
                        self._send_xml(404, "<Error><Code>BlobNotFound</Code></Error>")
                        return
                    copied = dict(src_item)
                    copied["meta"] = dict(src_item["meta"])
                    copied["modified"] = datetime.datetime.now(datetime.timezone.utc).timestamp()
                    state.blobs[blob] = copied
                self._send_bytes(202, b"", {"ETag": copied["etag"], "x-ms-copy-status": "success"})
                return

            etag = f'"0x{hashlib.md5(body).hexdigest()[:12]}"'
            with state.lock:
                state.blobs[blob] = {
                    "data": body,
                    "content_type": self.headers.get("Content-Type") or "application/octet-stream",
                    "cache_control": self.headers.get("Cache-Control") or "",
                    "access_tier": "Hot",
                    "etag": etag,
                    "meta": {},
                    "modified": datetime.datetime.now(datetime.timezone.utc).timestamp(),
                }
            self._send_bytes(201, b"", {"ETag": etag})

        def do_DELETE(self):
            ctx = self._authorize()
            if not ctx:
                return
            _, _, blob = ctx
            _ = self._read_body()
            with state.lock:
                if blob not in state.blobs:
                    self._send_xml(404, "<Error><Code>BlobNotFound</Code></Error>")
                    return
                del state.blobs[blob]
            self._send_bytes(202)

    return AzureHandler


# ---------------------------------------------------------------------------
# 5. OpenStack Swift Fixture Server
# ---------------------------------------------------------------------------

class SwiftState:
    def __init__(self, port_holder: list[int]):
        self.lock = threading.RLock()
        self.port_holder = port_holder
        self.token = "swift-fixture-token"
        self.objects: dict[str, dict] = {}
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        seed = b"fixture content"
        self.objects["中文 seed.txt"] = {
            "data": seed,
            "content_type": "text/plain; charset=utf-8",
            "etag": hashlib.md5(seed).hexdigest(),
            "meta": {},
            "modified": now,
        }


def make_swift_handler(state: SwiftState):
    class SwiftHandler(FixtureHTTPHandler):
        def _require_token(self) -> bool:
            if self.headers.get("X-Auth-Token") != state.token:
                self._send_bytes(401, b"Unauthorized")
                return False
            return True

        def _parse_storage_path(self, raw_path: str) -> tuple[str, str] | None:
            decoded = urllib.parse.unquote(raw_path)
            prefix = f"/v1/{SWIFT_ACCOUNT}/"
            if not decoded.startswith(prefix):
                return None
            rest = decoded[len(prefix):]
            cont, _, obj = rest.partition("/")
            return cont, obj

        def _copy_object(self, src_header: str, dst_key: str):
            decoded = urllib.parse.unquote(src_header).lstrip("/")
            src_cont, _, src_key = decoded.partition("/")
            with state.lock:
                src_obj = state.objects.get(src_key) if src_cont == SWIFT_ACCOUNT or src_cont == "fixture-container" else None
                if not src_obj:
                    self._send_bytes(404)
                    return
                copied = dict(src_obj)
                copied["meta"] = dict(src_obj["meta"])
                copied["modified"] = datetime.datetime.now(datetime.timezone.utc).timestamp()
                state.objects[dst_key] = copied
            self._send_bytes(201, b"", {"ETag": copied["etag"]})

        def do_GET(self):
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path in ("/auth/v1.0", "/v1.0"):
                auth_user = self.headers.get("X-Auth-User") or ""
                auth_key = self.headers.get("X-Auth-Key") or ""
                if auth_user not in (f"{SWIFT_TENANT}:{SWIFT_USER}", SWIFT_USER) or auth_key != SWIFT_PASS:
                    self._send_bytes(401, b"Unauthorized")
                    return
                port = state.port_holder[0]
                self._send_bytes(200, b"", {
                    "X-Auth-Token": state.token,
                    "X-Storage-Url": f"https://127.0.0.1:{port}/v1/{SWIFT_ACCOUNT}",
                })
                return

            if not self._require_token():
                return
            parts = self._parse_storage_path(parsed.path)
            if not parts or parts[0] != "fixture-container":
                self._send_bytes(404)
                return
            _, obj_key = parts
            q = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))

            if obj_key == "" and q.get("format") == "json":
                prefix = q.get("prefix", "")
                delimiter = q.get("delimiter", "")
                marker = q.get("marker", "")
                with state.lock:
                    items: list[dict] = []
                    seen_subdirs: set[str] = set()
                    for k in sorted(state.objects.keys()):
                        if not k.startswith(prefix):
                            continue
                        if delimiter and k == prefix:
                            continue
                        rel = k[len(prefix):]
                        if delimiter and delimiter in rel:
                            sub = prefix + rel.split(delimiter, 1)[0] + delimiter
                            if sub not in seen_subdirs:
                                seen_subdirs.add(sub)
                                items.append({"subdir": sub})
                        else:
                            meta = state.objects[k]
                            items.append({
                                "name": k,
                                "bytes": len(meta["data"]),
                                "last_modified": iso8601_micro(meta["modified"]),
                                "hash": meta["etag"],
                                "content_type": meta["content_type"],
                            })
                    if marker:
                        items = [it for it in items if (it.get("name") or it.get("subdir", "")) > marker]
                self._send_json(200, items)
                return

            with state.lock:
                obj = state.objects.get(obj_key)
                if not obj:
                    self._send_bytes(404)
                    return
                data = obj["data"]
                headers = {
                    "Content-Type": obj["content_type"],
                    "ETag": obj["etag"],
                    "Last-Modified": rfc1123(obj["modified"]),
                }
            self._send_file_or_range(data, headers)

        def do_HEAD(self):
            if not self._require_token():
                return
            parsed = urllib.parse.urlsplit(self.path)
            parts = self._parse_storage_path(parsed.path)
            if not parts or parts[0] != "fixture-container":
                self._send_bytes(404, b"", head_only=True)
                return
            _, obj_key = parts
            with state.lock:
                obj = state.objects.get(obj_key)
                if not obj:
                    self._send_bytes(404, b"", head_only=True)
                    return
                headers = {
                    "Content-Type": obj["content_type"],
                    "Content-Length": str(len(obj["data"])),
                    "ETag": obj["etag"],
                    "Last-Modified": rfc1123(obj["modified"]),
                }
                for mk, mv in obj["meta"].items():
                    headers[f"X-Object-Meta-{mk}"] = mv
            self._send_bytes(200, b"", headers, head_only=True)

        def do_PUT(self):
            if not self._require_token():
                return
            body = self._read_body()
            parsed = urllib.parse.urlsplit(self.path)
            parts = self._parse_storage_path(parsed.path)
            if not parts or parts[0] != "fixture-container":
                self._send_bytes(404)
                return
            _, obj_key = parts
            if copy_from := self.headers.get("X-Copy-From"):
                self._copy_object(copy_from, obj_key)
                return
            etag = hashlib.md5(body).hexdigest()
            meta = {
                k[len("X-Object-Meta-"):].lower(): v
                for k, v in self.headers.items()
                if k.lower().startswith("x-object-meta-")
            }
            with state.lock:
                state.objects[obj_key] = {
                    "data": body,
                    "content_type": self.headers.get("Content-Type") or "application/octet-stream",
                    "etag": etag,
                    "meta": meta,
                    "modified": datetime.datetime.now(datetime.timezone.utc).timestamp(),
                }
            self._send_bytes(201, b"", {"ETag": etag})

        def do_COPY(self):
            if not self._require_token():
                return
            _ = self._read_body()
            parsed = urllib.parse.urlsplit(self.path)
            parts = self._parse_storage_path(parsed.path)
            dest = self.headers.get("Destination")
            if not parts or parts[0] != "fixture-container" or not dest:
                self._send_bytes(400)
                return
            _, src_key = parts
            dest_decoded = urllib.parse.unquote(dest).lstrip("/")
            _, _, dst_key = dest_decoded.partition("/")
            self._copy_object(f"/fixture-container/{src_key}", dst_key)

        def do_POST(self):
            if not self._require_token():
                return
            _ = self._read_body()
            parsed = urllib.parse.urlsplit(self.path)
            parts = self._parse_storage_path(parsed.path)
            if not parts or parts[0] != "fixture-container":
                self._send_bytes(404)
                return
            _, obj_key = parts
            with state.lock:
                obj = state.objects.get(obj_key)
                if not obj:
                    self._send_bytes(404)
                    return
                if ct := self.headers.get("Content-Type"):
                    obj["content_type"] = ct
                obj["meta"] = {
                    k[len("X-Object-Meta-"):].lower(): v
                    for k, v in self.headers.items()
                    if k.lower().startswith("x-object-meta-")
                }
            self._send_bytes(202)

        def do_DELETE(self):
            if not self._require_token():
                return
            _ = self._read_body()
            parsed = urllib.parse.urlsplit(self.path)
            parts = self._parse_storage_path(parsed.path)
            if not parts or parts[0] != "fixture-container":
                self._send_bytes(404)
                return
            _, obj_key = parts
            with state.lock:
                if obj_key not in state.objects:
                    self._send_bytes(404)
                    return
                del state.objects[obj_key]
            self._send_bytes(204)

    return SwiftHandler


# ---------------------------------------------------------------------------
# Server Harness & Lifecycle
# ---------------------------------------------------------------------------

def generate_ephemeral_ca(certs_dir: Path) -> tuple[Path, Path, Path]:
    now = datetime.datetime.now(datetime.timezone.utc)
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "AetherTransfer Fixture CA")])
    ca_cert = (
        x509.CertificateBuilder()
        .subject_name(ca_name)
        .issuer_name(ca_name)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=False,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .sign(ca_key, hashes.SHA256())
    )

    srv_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    srv_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
    srv_cert = (
        x509.CertificateBuilder()
        .subject_name(srv_name)
        .issuer_name(ca_name)
        .public_key(srv_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=True,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .add_extension(
            x509.SubjectAlternativeName([
                x509.DNSName("localhost"),
                x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
            ]),
            critical=False,
        )
        .sign(ca_key, hashes.SHA256())
    )

    ca_path = certs_dir / "fixture-ca.pem"
    ca_path.write_bytes(ca_cert.public_bytes(serialization.Encoding.PEM))
    srv_path = certs_dir / "fixture-server.pem"
    srv_path.write_bytes(srv_cert.public_bytes(serialization.Encoding.PEM))
    key_path = certs_dir / "fixture-key.pem"
    key_path.write_bytes(
        srv_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    key_path.chmod(0o600)
    return ca_path, srv_path, key_path


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def start_http_server(handler_cls, tls_context: ssl.SSLContext | None = None) -> tuple[ReusableThreadingHTTPServer, threading.Thread, int]:
    httpd = ReusableThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
    if tls_context is not None:
        httpd.socket = tls_context.wrap_socket(httpd.socket, server_side=True)
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
    thread.start()
    return httpd, thread, port


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="aethertransfer-fixture-") as directory:
        base = Path(directory)
        certs_dir = base / "_certs"
        certs_dir.mkdir()
        cert_path, srv_cert_path, key_path = generate_ephemeral_ca(certs_dir)

        tls_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_ctx.load_cert_chain(certfile=str(srv_cert_path), keyfile=str(key_path))

        def make_seeded_root(name: str) -> Path:
            p = base / name
            p.mkdir()
            (p / "中文 seed.txt").write_text("fixture content", encoding="utf8")
            return p

        ftp_root = make_seeded_root("ftp")
        ftps_root = make_seeded_root("ftps")
        ftps_explicit_root = make_seeded_root("ftps_explicit")
        sftp_root = make_seeded_root("sftp")
        webdav_root = make_seeded_root("webdav")
        webdavs_root = make_seeded_root("webdavs")

        stopping = threading.Event()

        def serve_ftp(server: FTPServer):
            try:
                while not stopping.is_set():
                    server.ioloop.loop(timeout=0.1, blocking=False)
            finally:
                server.close_all()

        # 1. Plain FTP
        ftp_auth = DummyAuthorizer()
        ftp_auth.add_user(FIXTURE_USER, FIXTURE_PASS, str(ftp_root), perm="elradfmwMT")
        class PlainFTPHandler(FTPHandler):
            authorizer = ftp_auth
        ftp_server = FTPServer(("127.0.0.1", 0), PlainFTPHandler)
        ftp_thread = threading.Thread(target=serve_ftp, args=(ftp_server,), daemon=True)
        ftp_thread.start()

        # 2. FTPS Implicit
        ftps_auth = DummyAuthorizer()
        ftps_auth.add_user(FIXTURE_USER, FIXTURE_PASS, str(ftps_root), perm="elradfmwMT")
        class ImplicitTLSHandler(TLS_FTPHandler):
            certfile = str(srv_cert_path)
            keyfile = str(key_path)
            ssl_context = None
            tls_control_required = True
            tls_data_required = True
            authorizer = ftps_auth
            def handle(self):
                self.secure_connection(self.ssl_context)
                super().handle()
        ftps_loop = IOLoop()
        ftps_server = FTPServer(("127.0.0.1", 0), ImplicitTLSHandler, ioloop=ftps_loop)
        ftps_thread = threading.Thread(target=serve_ftp, args=(ftps_server,), daemon=True)
        ftps_thread.start()

        # 3. FTPS Explicit (AUTH TLS)
        ftps_exp_auth = DummyAuthorizer()
        ftps_exp_auth.add_user(FIXTURE_USER, FIXTURE_PASS, str(ftps_explicit_root), perm="elradfmwMT")
        class ExplicitTLSHandler(TLS_FTPHandler):
            certfile = str(srv_cert_path)
            keyfile = str(key_path)
            ssl_context = None
            tls_control_required = True
            tls_data_required = True
            authorizer = ftps_exp_auth
        ftps_exp_loop = IOLoop()
        ftps_exp_server = FTPServer(("127.0.0.1", 0), ExplicitTLSHandler, ioloop=ftps_exp_loop)
        ftps_exp_thread = threading.Thread(target=serve_ftp, args=(ftps_exp_server,), daemon=True)
        ftps_exp_thread.start()

        # 4. SFTP
        sftp_key = paramiko.RSAKey.generate(2048)
        sftp_listener = socket.socket()
        sftp_listener.bind(("127.0.0.1", 0))
        sftp_listener.listen(32)
        sftp_lock = threading.Lock()
        sftp_transports: list[paramiko.Transport] = []
        sftp_conn_threads: list[threading.Thread] = []

        def handle_sftp(connection: socket.socket):
            transport = paramiko.Transport(connection)
            with sftp_lock:
                sftp_transports.append(transport)
            transport.add_server_key(sftp_key)
            transport.set_subsystem_handler("sftp", paramiko.SFTPServer, SFTPFiles, root=sftp_root)
            try:
                transport.start_server(server=SFTPAuth())
                while transport.is_active() and not stopping.is_set():
                    transport.join(timeout=0.2)
            except (EOFError, paramiko.SSHException, OSError):
                pass
            finally:
                try:
                    transport.close()
                except Exception:
                    pass

        def accept_sftp():
            while not stopping.is_set():
                try:
                    connection, _ = sftp_listener.accept()
                except OSError:
                    return
                t = threading.Thread(target=handle_sftp, args=(connection,), daemon=True)
                with sftp_lock:
                    sftp_conn_threads.append(t)
                t.start()

        sftp_accept_thread = threading.Thread(target=accept_sftp, daemon=True)
        sftp_accept_thread.start()

        # 5. WebDAV HTTP + HTTPS
        webdav_httpd, webdav_thread, webdav_port = start_http_server(make_webdav_handler(WebDAVState(webdav_root)))
        webdavs_httpd, webdavs_thread, webdavs_port = start_http_server(make_webdav_handler(WebDAVState(webdavs_root)), tls_context=tls_ctx)

        # 6. S3 HTTPS & STS HTTPS
        s3_httpd, s3_thread, s3_port = start_http_server(make_s3_handler(S3State(page_limit=2)), tls_context=tls_ctx)
        sts_httpd, sts_thread, sts_port = start_http_server(make_sts_handler(), tls_context=tls_ctx)

        # 7. Backblaze B2 HTTPS
        b2_port_holder = [0]
        b2_state = B2State(b2_port_holder, page_limit=2)
        b2_httpd, b2_thread, b2_port = start_http_server(make_b2_handler(b2_state), tls_context=tls_ctx)
        b2_port_holder[0] = b2_port

        # 8. Azure Blob HTTPS
        azure_httpd, azure_thread, azure_port = start_http_server(make_azure_handler(AzureState(page_limit=2)), tls_context=tls_ctx)

        # 9. OpenStack Swift HTTPS
        swift_port_holder = [0]
        swift_state = SwiftState(swift_port_holder)
        swift_httpd, swift_thread, swift_port = start_http_server(make_swift_handler(swift_state), tls_context=tls_ctx)
        swift_port_holder[0] = swift_port

        http_servers = [
            (webdav_httpd, webdav_thread),
            (webdavs_httpd, webdavs_thread),
            (s3_httpd, s3_thread),
            (sts_httpd, sts_thread),
            (b2_httpd, b2_thread),
            (azure_httpd, azure_thread),
            (swift_httpd, swift_thread),
        ]

        env = os.environ.copy()
        env.update(
            AT_FTP_PORT=str(ftp_server.socket.getsockname()[1]),
            AT_FTPS_PORT=str(ftps_server.socket.getsockname()[1]),
            AT_FTPS_EXPLICIT_PORT=str(ftps_exp_server.socket.getsockname()[1]),
            AT_FTPS_CA=str(cert_path),
            AT_SFTP_PORT=str(sftp_listener.getsockname()[1]),
            AT_SFTP_KEY=sftp_key.get_base64(),
            AT_WEBDAV_PORT=str(webdav_port),
            AT_WEBDAVS_PORT=str(webdavs_port),
            AT_S3_PORT=str(s3_port),
            AT_STS_PORT=str(sts_port),
            AT_B2_PORT=str(b2_port),
            AT_AZURE_PORT=str(azure_port),
            AT_SWIFT_PORT=str(swift_port),
            AT_AZURE_SHARED_KEY=AZURE_SHARED_KEY_B64,
        )

        try:
            result = subprocess.run(
                ["swift", "test", "--filter", "ProtocolIntegrationTests|FTPSIntegrationTests"],
                env=env,
            )
        finally:
            stopping.set()
            for httpd, thread in http_servers:
                try:
                    httpd.shutdown()
                    httpd.server_close()
                except Exception:
                    pass
                thread.join(timeout=5)
            ftp_thread.join(timeout=5)
            ftps_thread.join(timeout=5)
            ftps_exp_thread.join(timeout=5)
            try:
                sftp_listener.close()
            except Exception:
                pass
            with sftp_lock:
                transports = list(sftp_transports)
                conn_threads = list(sftp_conn_threads)
            for transport in transports:
                try:
                    transport.close()
                except Exception:
                    pass
            sftp_accept_thread.join(timeout=5)
            for t in conn_threads:
                t.join(timeout=2)

        return result.returncode


if __name__ == "__main__":
    sys.exit(main())
