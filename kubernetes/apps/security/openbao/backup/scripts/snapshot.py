"""Download and retain validated OpenBao 2.7 Raft snapshots.

Archive layout and checksums follow OpenBao v2.7.0's
internal/physical/raft/snapshot/archive.go. This process never prints response bodies.
"""

import gzip
import hashlib
import http.client
import json
import os
import re
import shutil
import socket
import ssl
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path


PEERS = tuple(f"openbao-{number}.openbao-internal.openbao.svc" for number in range(3))
SERVER_NAME = "openbao.lab.supermorphic.com"
MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
KEEP = 7


class SnapshotError(Exception):
    """A safe, non-secret failure category."""


def archive_index(path: Path) -> int:
    """Verify the upstream gzip/tar archive, member sizes and SHA256SUMS."""
    try:
        sums = {}
        expected = {}
        seen = set()
        metadata = None
        with tarfile.open(path, "r:gz") as archive:
            for member in archive:
                name = member.name
                if name not in {"meta.json", "state.bin", "SHA256SUMS", "SHA256SUMS.sealed"} or \
                        name in seen or not member.isfile():
                    raise SnapshotError("archive-invalid")
                seen.add(name)
                stream = archive.extractfile(member)
                if stream is None:
                    raise SnapshotError("archive-invalid")
                if name in {"meta.json", "SHA256SUMS", "SHA256SUMS.sealed"} and member.size > 8192:
                    raise SnapshotError("archive-invalid")
                digest = hashlib.sha256()
                read = 0
                content = bytearray() if name != "state.bin" else None
                while chunk := stream.read(1024 * 1024):
                    digest.update(chunk)
                    read += len(chunk)
                    if content is not None:
                        content.extend(chunk)
                if read != member.size:
                    raise SnapshotError("archive-invalid")
                if name == "SHA256SUMS.sealed" and read == 0:
                    raise SnapshotError("archive-invalid")
                if name in {"meta.json", "state.bin"}:
                    sums[name] = digest.hexdigest()
                if name == "meta.json":
                    metadata = json.loads(content)
                if name == "SHA256SUMS":
                    expected = {}
                    for line in content.decode("ascii").splitlines():
                        match = re.fullmatch(r"([0-9a-f]{64})  (meta\.json|state\.bin)", line)
                        if not match or match.group(2) in expected:
                            raise SnapshotError("archive-invalid")
                        expected[match.group(2)] = match.group(1)
        # tarfile stops at the tar end marker; consume gzip EOF too so a missing
        # trailer or a truncated final block cannot pass archive validation.
        with gzip.open(path, "rb") as compressed:
            while compressed.read(1024 * 1024):
                pass
        if not {"meta.json", "state.bin", "SHA256SUMS"}.issubset(seen) or \
                expected != sums or not isinstance(metadata, dict) or \
                type(metadata.get("Index")) is not int or metadata["Index"] <= 0 or \
                metadata.get("Size") != path_state_size(path):
            raise SnapshotError("archive-invalid")
        return metadata["Index"]
    except (OSError, EOFError, ValueError, UnicodeError, tarfile.TarError, KeyError, TypeError):
        raise SnapshotError("archive-invalid") from None


def path_state_size(path: Path) -> int:
    with tarfile.open(path, "r:gz") as archive:
        return archive.getmember("state.bin").size


class PeerConnection(http.client.HTTPSConnection):
    """Connect to one exact peer while validating the shared certificate name."""

    def __init__(self, peer: str):
        super().__init__(peer, 8200, timeout=30, context=ssl.create_default_context())

    def connect(self):
        raw = socket.create_connection((self.host, self.port), self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=SERVER_NAME)
        except BaseException:
            raw.close()
            raise


class BaoClient:
    def __init__(self, jwt_path: Path):
        self.jwt_path = jwt_path

    def _request(self, peer: str, method: str, path: str, body=None, token=None):
        if peer not in PEERS:
            raise SnapshotError("peer-invalid")
        connection = PeerConnection(peer)
        headers = {"Accept": "application/json", "X-Vault-No-Request-Forwarding": "true"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if token is not None:
            headers["X-Vault-Token"] = token
        try:
            connection.request(method, path, body=body, headers=headers)
            return connection, connection.getresponse()
        except (OSError, http.client.HTTPException, ssl.SSLError):
            connection.close()
            raise SnapshotError("request-failed") from None

    def _json(self, peer, method, path, body=None):
        connection, response = self._request(peer, method, path, body)
        try:
            if response.status != 200:
                raise SnapshotError("request-failed")
            data = response.read(MAX_RESPONSE_BYTES + 1)
            if len(data) > MAX_RESPONSE_BYTES:
                raise SnapshotError("request-failed")
            return json.loads(data)
        except (ValueError, OSError, http.client.HTTPException):
            raise SnapshotError("request-failed") from None
        finally:
            connection.close()

    def leader(self):
        active = []
        for peer in PEERS:
            connection, response = self._request(peer, "GET", "/v1/sys/health")
            try:
                if response.status == 200:
                    active.append(peer)
                elif response.status not in (429, 472, 473):
                    raise SnapshotError("leader-unavailable")
                response.read(MAX_RESPONSE_BYTES + 1)
            finally:
                connection.close()
        if len(active) != 1:
            raise SnapshotError("leader-ambiguous")
        return active[0]

    def version(self, peer):
        health = self._json(peer, "GET", "/v1/sys/health")
        version = health.get("version")
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
            raise SnapshotError("version-invalid")
        return version

    def download(self, peer, output, limit):
        try:
            jwt = self.jwt_path.read_text().strip()
            if not jwt:
                raise SnapshotError("login-failed")
            login = self._json(peer, "POST", "/v1/auth/homelab-jwt/login",
                               json.dumps({"role": "openbao-backup", "jwt": jwt}))
            token = login["auth"]["client_token"]
            if not isinstance(token, str) or not token:
                raise SnapshotError("login-failed")
            connection, response = self._request(
                peer, "GET", "/v1/sys/storage/raft/snapshot", token=token)
            try:
                if response.status != 200:
                    raise SnapshotError("download-failed")
                length = response.getheader("Content-Length")
                if length is not None and (not length.isdigit() or int(length) > limit):
                    raise SnapshotError("download-failed")
                count = 0
                while chunk := response.read(1024 * 1024):
                    count += len(chunk)
                    if count > limit:
                        raise SnapshotError("download-failed")
                    output.write(chunk)
                if count == 0 or (length is not None and count != int(length)):
                    raise SnapshotError("download-failed")
            finally:
                connection.close()
        except (OSError, KeyError, TypeError, http.client.HTTPException):
            raise SnapshotError("download-failed") from None


def _sync_dir(path: Path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _attempt(client, root: Path, now: datetime) -> dict:
    peer = client.leader()
    version = client.version(peer)
    pending = Path(tempfile.mkdtemp(prefix=".pending-", dir=root))
    try:
        file = pending / "raft.snap"
        with file.open("xb") as output:
            try:
                client.download(peer, output, MAX_SNAPSHOT_BYTES)
            except SnapshotError:
                # One failed attempt may be an election during transfer. A
                # stable leader failure remains a failure, without retrying
                # the same target or following an HTTP redirect.
                try:
                    moved = client.leader() != peer
                except SnapshotError:
                    raise SnapshotError("download-failed") from None
                if moved:
                    raise SnapshotError("leader-changed") from None
                raise
            output.flush()
            os.fsync(output.fileno())
        index = archive_index(file)
        if client.leader() != peer or client.version(peer) != version:
            raise SnapshotError("leader-changed")
        with file.open("rb") as saved:
            digest = hashlib.file_digest(saved, "sha256").hexdigest()
        created = now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        metadata = {"created_at": created, "openbao_version": version,
                    "raft_index": index, "seal_key_id": os.environ.get("OPENBAO_SEAL_KEY_ID", "openbao-static-seal-v1"),
                    "recovery_generation": os.environ.get("OPENBAO_RECOVERY_GENERATION", "1"),
                    "sha256": digest}
        with (pending / "metadata.json").open("x") as output:
            json.dump(metadata, output, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        _sync_dir(pending)
        target = root / ("snapshot-" + created.replace(":", ""))
        if target.exists():
            raise SnapshotError("snapshot-exists")
        os.replace(pending, target)
        _sync_dir(root)
        latest = root / ".latest-pending"
        try:
            with latest.open("w") as output:
                output.write(target.name + "\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(latest, root / "latest")
            _sync_dir(root)
        except OSError:
            latest.unlink(missing_ok=True)
            # The previous latest remains the committed usable pair. This new
            # directory was never published and must not consume retention.
            pointer = root / "latest"
            if not pointer.exists() or pointer.read_text().strip() != target.name:
                shutil.rmtree(target)
            raise
        for stale in sorted(root.glob("snapshot-*"), reverse=True)[KEEP:]:
            if stale.is_dir() and stale.name != target.name:
                shutil.rmtree(stale)
        return metadata
    finally:
        if pending.exists():
            shutil.rmtree(pending)


def run(client, backup_dir: Path, clock) -> dict:
    """Install one validated pair; keep seven successful pairs only."""
    try:
        backup_dir.mkdir(parents=True, exist_ok=True)
        now = clock()
        if not isinstance(now, datetime) or now.tzinfo is None:
            raise SnapshotError("clock-invalid")
        for attempt in range(2):
            try:
                return _attempt(client, backup_dir, now)
            except SnapshotError as error:
                if str(error) != "leader-changed" or attempt:
                    raise
        raise SnapshotError("leader-changed")
    except (OSError, ValueError, TypeError, tarfile.TarError):
        raise SnapshotError("snapshot-failed") from None


if __name__ == "__main__":
    try:
        result = run(BaoClient(Path("/var/run/openbao-backup/token")),
                     Path("/backup"), lambda: datetime.now(timezone.utc))
        print(json.dumps({"created_at": result["created_at"], "sha256": result["sha256"]}))
    except SnapshotError:
        print("openbao backup failed", file=sys.stderr)
        sys.exit(1)
