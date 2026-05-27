# VersionTag: 2605.B5.V46.0
# VersionTag: 2605.B5.V46.0
# VersionTag: 2605.B5.V46.0
# VersionTag: 2605.B5.V46.0
"""
FocalPoint-null PKI Manager
RSA-2048 certificate generation, signing and verification for inter-agent identity.
Agents present their certificate (public key) to initiate contact.
All cross-agent communication is brokered by FocalPoint-null-00.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import NameOID

from core.models import AgentCertificate, CertStatus


class PKIManager:
    """
    Manages agent identity using RSA-2048 certificates.
    - Issues a self-signed certificate per agent on first use.
    - Signs payloads with the issuing agent's private key.
    - Verifies sender signatures using the registered public key.
    - Certificates stored as PEM files in pki/<agent_id>.pem and pki/<agent_id>.pub
    """

    def __init__(self, pki_dir: str = "pki"):
        self.pki_dir = Path(pki_dir)
        self.pki_dir.mkdir(parents=True, exist_ok=True)
        self._private_keys: dict[str, rsa.RSAPrivateKey] = {}
        self._certificates: dict[str, x509.Certificate] = {}

    # ─────────────────────────────────────────────
    # KEY & CERTIFICATE GENERATION
    # ─────────────────────────────────────────────

    def generate_agent_keypair(
        self,
        agent_id: str,
        validity_days: int = 365,
        force: bool = False,
    ) -> AgentCertificate:
        """Generate RSA-2048 keypair and self-signed certificate for an agent."""
        cert_path = self.pki_dir / f"{agent_id}.pem"
        key_path = self.pki_dir / f"{agent_id}.key"
        pub_path = self.pki_dir / f"{agent_id}.pub"

        if cert_path.exists() and not force:
            return self.load_agent_certificate(agent_id)

        # Generate private key
        private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
        )

        # Build self-signed certificate
        now = datetime.now(timezone.utc)
        subject = x509.Name([
            x509.NameAttribute(NameOID.COMMON_NAME, agent_id),
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "FocalPoint-null"),
        ])
        cert = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(private_key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now)
            .not_valid_after(now + timedelta(days=validity_days))
            .add_extension(
                x509.SubjectAlternativeName([
                    x509.DNSName(agent_id),
                    x509.RFC822Name(f"{agent_id}@focalpoint-null.local"),
                ]),
                critical=False,
            )
            .add_extension(
                x509.KeyUsage(
                    digital_signature=True,
                    content_commitment=True,
                    key_encipherment=True,
                    data_encipherment=False,
                    key_agreement=False,
                    key_cert_sign=True,
                    crl_sign=False,
                    encipher_only=False,
                    decipher_only=False,
                ),
                critical=True,
            )
            .sign(private_key, hashes.SHA256())
        )

        # Serialize and write
        cert_pem = cert.public_bytes(serialization.Encoding.PEM).decode()
        pub_pem = private_key.public_key().public_bytes(
            serialization.Encoding.PEM,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        ).decode()
        key_pem = private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        )

        cert_path.write_text(cert_pem)
        pub_path.write_text(pub_pem)
        # Key is written with restricted permissions
        key_path.write_bytes(key_pem)
        try:
            os.chmod(str(key_path), 0o600)
        except Exception:
            pass  # Windows doesn't support POSIX chmod; accept limitation

        fingerprint = self._cert_fingerprint(cert)
        self._private_keys[agent_id] = private_key
        self._certificates[agent_id] = cert

        return AgentCertificate(
            agent_id=agent_id,
            public_key_pem=pub_pem,
            cert_pem=cert_pem,
            fingerprint_sha256=fingerprint,
            issued_at=now,
            expires_at=now + timedelta(days=validity_days),
        )

    def load_agent_certificate(self, agent_id: str) -> AgentCertificate:
        """Load an existing certificate from disk."""
        cert_path = self.pki_dir / f"{agent_id}.pem"
        pub_path = self.pki_dir / f"{agent_id}.pub"
        key_path = self.pki_dir / f"{agent_id}.key"

        if not cert_path.exists():
            raise FileNotFoundError(f"Certificate not found for agent: {agent_id}. Run generate_agent_keypair first.")

        cert_pem = cert_path.read_text()
        pub_pem = pub_path.read_text() if pub_path.exists() else ""

        cert = x509.load_pem_x509_certificate(cert_pem.encode())
        fingerprint = self._cert_fingerprint(cert)

        if key_path.exists() and agent_id not in self._private_keys:
            private_key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
            self._private_keys[agent_id] = private_key  # type: ignore

        self._certificates[agent_id] = cert

        return AgentCertificate(
            agent_id=agent_id,
            public_key_pem=pub_pem,
            cert_pem=cert_pem,
            fingerprint_sha256=fingerprint,
            issued_at=cert.not_valid_before_utc,
            expires_at=cert.not_valid_after_utc,
        )

    # ─────────────────────────────────────────────
    # SIGNING
    # ─────────────────────────────────────────────

    def sign_payload(self, agent_id: str, payload_json: str) -> tuple[str, str]:
        """
        Sign a payload with the agent's private key.
        Returns (payload_sha256, base64_signature).
        """
        if agent_id not in self._private_keys:
            self.load_agent_certificate(agent_id)
        if agent_id not in self._private_keys:
            raise RuntimeError(f"No private key loaded for agent: {agent_id}")

        payload_bytes = payload_json.encode("utf-8")
        sha256 = hashlib.sha256(payload_bytes).hexdigest()

        private_key = self._private_keys[agent_id]
        signature = private_key.sign(
            payload_bytes,
            padding.PKCS1v15(),
            hashes.SHA256(),
        )
        b64_sig = base64.b64encode(signature).decode("utf-8")
        return sha256, b64_sig

    def verify_payload(
        self,
        sender_agent_id: str,
        payload_json: str,
        b64_signature: str,
        expected_sha256: Optional[str] = None,
    ) -> bool:
        """
        Verify a payload's signature against the sender's public key.
        Returns True if valid, False otherwise.
        """
        try:
            if sender_agent_id not in self._certificates:
                self.load_agent_certificate(sender_agent_id)

            cert = self._certificates.get(sender_agent_id)
            if not cert:
                return False

            public_key = cert.public_key()
            payload_bytes = payload_json.encode("utf-8")
            signature = base64.b64decode(b64_signature)

            public_key.verify(signature, payload_bytes, padding.PKCS1v15(), hashes.SHA256())  # type: ignore

            if expected_sha256:
                actual_sha256 = hashlib.sha256(payload_bytes).hexdigest()
                return actual_sha256 == expected_sha256

            return True
        except Exception:
            return False

    # ─────────────────────────────────────────────
    # UTILITY
    # ─────────────────────────────────────────────

    def get_public_key_pem(self, agent_id: str) -> str:
        pub_path = self.pki_dir / f"{agent_id}.pub"
        if pub_path.exists():
            return pub_path.read_text()
        cert = self._certificates.get(agent_id)
        if cert:
            return cert.public_key().public_bytes(
                serialization.Encoding.PEM,
                serialization.PublicFormat.SubjectPublicKeyInfo,
            ).decode()
        raise FileNotFoundError(f"No public key for agent: {agent_id}")

    def is_cert_valid(self, agent_id: str) -> bool:
        """Check if the agent certificate is currently valid (not expired, not revoked)."""
        try:
            cert = self._certificates.get(agent_id)
            if not cert:
                self.load_agent_certificate(agent_id)
                cert = self._certificates.get(agent_id)
            if not cert:
                return False
            now = datetime.now(timezone.utc)
            return cert.not_valid_before_utc <= now <= cert.not_valid_after_utc
        except Exception:
            return False

    @staticmethod
    def _cert_fingerprint(cert: x509.Certificate) -> str:
        return cert.fingerprint(hashes.SHA256()).hex()

    def ensure_all_agent_certs(self, agent_ids: list[str], validity_days: int = 365) -> dict[str, AgentCertificate]:
        """Bootstrap PKI for all known agents."""
        result = {}
        for agent_id in agent_ids:
            try:
                result[agent_id] = self.generate_agent_keypair(agent_id, validity_days)
            except Exception as e:
                # Log but continue — partial PKI is better than none
                print(f"[PKIManager] Warning: Could not generate keypair for {agent_id}: {e}")
        return result







