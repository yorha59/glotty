#!/usr/bin/env python3
"""Bootstrap Apple Distribution cert + Mac App Store provisioning profile
via the App Store Connect API.

Reads credentials from .env.appstore (APP_STORE_KEY_ID, APP_STORE_ISSUER_ID).
The .p8 private key file must already exist at
~/Library/MobileDevice/AppStoreConnect_AuthKey_<KEY_ID>.p8.

Produces:
  - An Apple Distribution certificate installed in the user's login
    keychain (with the private key, so codesign can use it).
  - A Mac App Store provisioning profile at
    ~/Library/MobileDevice/Provisioning Profiles/<UUID>.provisionprofile
    pointing at com.ruojunye.glotty and signed against the new cert.

After this script runs, scripts/upload-appstore.sh can build and upload
without further Apple-portal interaction.

Idempotency: if an Apple Distribution cert / profile already exist for
this bundle ID, the script reports and exits without recreating.
"""

from __future__ import annotations

import base64
import datetime as dt
import os
import pathlib
import subprocess
import sys
import time

import jwt  # PyJWT
import requests
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / ".env.appstore"
API_BASE = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID_IDENT = "com.ruojunye.glotty"
PROFILE_NAME = "Glotty Mac App Store"
PROFILES_DIR = pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles"


def load_env() -> tuple[str, str, pathlib.Path]:
    """Read .env.appstore and locate the .p8 key file."""
    if not ENV_FILE.exists():
        sys.exit(f"ERROR: {ENV_FILE} not found")
    env: dict[str, str] = {}
    for line in ENV_FILE.read_text().splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    key_id = env.get("APP_STORE_KEY_ID")
    issuer_id = env.get("APP_STORE_ISSUER_ID")
    if not key_id or not issuer_id:
        sys.exit("ERROR: APP_STORE_KEY_ID and APP_STORE_ISSUER_ID required in .env.appstore")
    p8_path = pathlib.Path.home() / f"Library/MobileDevice/AppStoreConnect_AuthKey_{key_id}.p8"
    if not p8_path.exists():
        sys.exit(f"ERROR: API key not found at {p8_path}")
    return key_id, issuer_id, p8_path


def make_jwt(key_id: str, issuer_id: str, p8_path: pathlib.Path) -> str:
    """Build the short-lived ES256 JWT App Store Connect API expects."""
    now = int(time.time())
    return jwt.encode(
        # Apple caps token lifetime at 20 minutes; 10 is plenty for our calls.
        {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        p8_path.read_text(),
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def api(token: str, method: str, path: str, **kwargs) -> dict:
    """Thin wrapper around requests with auth + error pretty-print."""
    url = f"{API_BASE}/{path.lstrip('/')}"
    r = requests.request(
        method,
        url,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        timeout=30,
        **kwargs,
    )
    if r.status_code >= 400:
        sys.exit(f"API {method} {path} -> {r.status_code}: {r.text}")
    return r.json() if r.text else {}


def cert_already_in_keychain(label: str) -> bool:
    """True if `security find-identity` shows a valid cert whose name
    matches `label` — meaning the local keychain has both the cert
    and the matching private key.

    Maps the API's cert-type label to the legacy display names that
    `security find-identity` uses. Installer certs in particular show
    up as "3rd Party Mac Developer Installer", not "Mac Installer
    Distribution" — same cert, older Apple branding.
    Also drops the `-p codesigning` policy filter so installer certs
    (which aren't a codesigning policy) are included.
    """
    aliases = {
        "Apple Distribution": ("Apple Distribution",),
        "Mac Installer Distribution": (
            "Mac Installer Distribution",
            "3rd Party Mac Developer Installer",
        ),
    }
    needles = aliases.get(label, (label,))
    out = subprocess.run(
        ["security", "find-identity", "-v"],
        capture_output=True, text=True, check=True,
    ).stdout
    return any(needle in out for needle in needles)


def mint_cert(
    token: str, cert_type: str, label: str
) -> tuple[str, bytes, rsa.RSAPrivateKey] | None:
    """Mint a fresh cert of the given type. Returns None if the cert is
    already present in the keychain AND at Apple — in that case the
    caller should skip the install step (nothing to do).

    With --revoke-existing on the command line, revokes any pre-existing
    cert of the same type before minting. Use this to recover from a
    prior run that created the Apple-side cert but failed to install
    the private key locally.

    Common cert_type values used here:
      DISTRIBUTION             — app binary (iOS / macOS App Store)
      MAC_INSTALLER_DISTRIBUTION — .pkg installer (macOS App Store only)
    """
    existing = api(token, "GET", f"certificates?filter[certificateType]={cert_type}")
    revoke = "--revoke-existing" in sys.argv

    for c in existing.get("data", []):
        attrs = c.get("attributes", {})
        if revoke:
            sys.stderr.write(
                f"==> Revoking existing {label} cert id={c['id']} "
                f"name='{attrs.get('name')}' (--revoke-existing)\n"
            )
            api(token, "DELETE", f"certificates/{c['id']}")
            continue
        # Cert exists at Apple. If the keychain also has it (which means
        # we have the private key), nothing to do — reuse.
        if cert_already_in_keychain(label):
            sys.stderr.write(
                f"==> {label} cert already at Apple AND in keychain — reusing id={c['id']}\n"
            )
            return None
        sys.stderr.write(
            f"==> Apple has a {label} cert (id={c['id']}) but the keychain "
            "doesn't — its private key is lost (probably from a prior crash).\n"
        )
        sys.exit(
            f"A {label} cert exists at Apple but not locally. Re-run with "
            "--revoke-existing to revoke the orphaned one and mint fresh, "
            "OR import the private key manually from another Mac."
        )

    sys.stderr.write(f"==> Generating private key + CSR for {label}\n")
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(
            x509.Name([
                x509.NameAttribute(NameOID.COMMON_NAME, f"Glotty {label}"),
                x509.NameAttribute(NameOID.EMAIL_ADDRESS, "hemoon@outlook.com"),
                x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
            ])
        )
        .sign(private_key, hashes.SHA256())
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    csr_inner = "".join(csr_pem.strip().splitlines()[1:-1])

    sys.stderr.write(f"==> Requesting {label} cert from Apple\n")
    resp = api(
        token,
        "POST",
        "certificates",
        json={
            "data": {
                "type": "certificates",
                "attributes": {
                    "csrContent": csr_inner,
                    "certificateType": cert_type,
                },
            }
        },
    )
    cert_id = resp["data"]["id"]
    cert_b64 = resp["data"]["attributes"]["certificateContent"]
    cert_der = base64.b64decode(cert_b64)
    return cert_id, cert_der, private_key


def find_or_create_distribution_cert(token: str):
    return mint_cert(token, "DISTRIBUTION", "Apple Distribution")

    sys.stderr.write("==> Generating private key + CSR locally\n")
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(
            x509.Name([
                x509.NameAttribute(NameOID.COMMON_NAME, "Glotty Apple Distribution"),
                x509.NameAttribute(NameOID.EMAIL_ADDRESS, "hemoon@outlook.com"),
                x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
            ])
        )
        .sign(private_key, hashes.SHA256())
    )
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    # Apple expects the CSR base64-encoded, sans the BEGIN/END markers.
    csr_inner = "".join(csr_pem.strip().splitlines()[1:-1])

    sys.stderr.write("==> Requesting Distribution cert from Apple\n")
    resp = api(
        token,
        "POST",
        "certificates",
        json={
            "data": {
                "type": "certificates",
                "attributes": {
                    "csrContent": csr_inner,
                    "certificateType": "DISTRIBUTION",
                },
            }
        },
    )
    cert_id = resp["data"]["id"]
    cert_b64 = resp["data"]["attributes"]["certificateContent"]
    cert_der = base64.b64decode(cert_b64)
    return cert_id, cert_der, private_key


def install_cert_in_keychain(
    cert_der: bytes, private_key: rsa.RSAPrivateKey, label: str = "Apple Distribution"
) -> None:
    """Package cert + private key into a .p12 and import into login.keychain.

    We delete the .p12 immediately after import — the cert + key live in
    the keychain encrypted at rest, the on-disk .p12 is transient.
    """
    sys.stderr.write(f"==> Packaging {label} cert + key into .p12 for keychain import\n")
    # Write cert + key to temp PEM files and use openssl to build the .p12,
    # which is more battle-tested than building the PKCS#12 in Python.
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        td_path = pathlib.Path(td)
        cert_pem = td_path / "cert.pem"
        key_pem = td_path / "key.pem"
        p12 = td_path / "bundle.p12"

        # Convert DER cert to PEM
        cert = x509.load_der_x509_certificate(cert_der)
        cert_pem.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        key_pem.write_bytes(
            private_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )
        # Build .p12 with a random transient password
        p12_pass = base64.urlsafe_b64encode(os.urandom(18)).decode()
        # `-legacy` forces 3DES/SHA1 PRF instead of OpenSSL 3.x's default
        # AES/SHA-256. macOS's Security framework's PKCS#12 importer
        # rejects the modern algorithms with "MAC verification failed"
        # — needs the legacy PRF.
        subprocess.run(
            [
                "openssl", "pkcs12", "-export", "-legacy",
                "-inkey", str(key_pem), "-in", str(cert_pem),
                "-out", str(p12),
                "-passout", f"pass:{p12_pass}",
                "-name", f"{label}: Glotty",
            ],
            check=True,
        )
        sys.stderr.write("==> Importing into login keychain (codesign will be able to use the private key)\n")
        subprocess.run(
            ["security", "import", str(p12), "-k", "login.keychain",
             "-P", p12_pass, "-T", "/usr/bin/codesign"],
            check=True,
        )

    # Verify the cert is now visible to codesign.
    out = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        capture_output=True, text=True, check=True,
    ).stdout
    if "Apple Distribution" not in out:
        sys.stderr.write(
            "WARNING: Apple Distribution cert imported but not visible as a "
            "valid codesigning identity. The cert chain may be missing the "
            "Apple WWDR intermediate. Trying to download + import it...\n"
        )
        wwdr_url = "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"
        wwdr = requests.get(wwdr_url, timeout=15).content
        wwdr_tmp = pathlib.Path("/tmp/AppleWWDRCAG3.cer")
        wwdr_tmp.write_bytes(wwdr)
        subprocess.run(["security", "import", str(wwdr_tmp), "-k", "login.keychain"], check=True)
        wwdr_tmp.unlink()


def find_bundle_id(token: str, identifier: str) -> str:
    """Look up the Apple-internal bundle ID resource for our identifier."""
    resp = api(token, "GET", f"bundleIds?filter[identifier]={identifier}")
    data = resp.get("data", [])
    if not data:
        sys.exit(
            f"ERROR: Bundle ID '{identifier}' is not registered at "
            "developer.apple.com → Identifiers. Register it (App IDs → App → "
            "Explicit) and re-run."
        )
    return data[0]["id"]


def create_mac_app_store_profile(
    token: str, bundle_id: str, cert_ids: list[str]
) -> dict:
    """Create (or recreate) the Mac App Store provisioning profile and
    return the JSON. The profile must reference BOTH the Apple
    Distribution cert (app-signing) AND the Mac Installer Distribution
    cert (.pkg-signing) — Xcode's export step verifies that the profile
    includes every cert it's about to use, including the installer.
    """
    # If an existing profile uses the same name, delete it. Profiles
    # are immutable — to "update" the cert list we recreate. Cheap.
    existing = api(token, "GET", "profiles")
    for p in existing.get("data", []):
        if p.get("attributes", {}).get("name") == PROFILE_NAME:
            sys.stderr.write(
                f"==> Deleting old provisioning profile id={p['id']} so we can recreate with current certs\n"
            )
            api(token, "DELETE", f"profiles/{p['id']}")

    sys.stderr.write(f"==> Creating Mac App Store provisioning profile '{PROFILE_NAME}'\n")
    resp = api(
        token,
        "POST",
        "profiles",
        json={
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": PROFILE_NAME,
                    "profileType": "MAC_APP_STORE",
                },
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                    "certificates": {
                        "data": [
                            {"type": "certificates", "id": cid}
                            for cid in cert_ids
                        ],
                    },
                },
            }
        },
    )
    return resp["data"]


def install_profile(profile: dict) -> None:
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    content_b64 = profile["attributes"]["profileContent"]
    # Apple uses the UUID as filename; matches Xcode's convention.
    uuid = profile["attributes"]["uuid"]
    out = PROFILES_DIR / f"{uuid}.provisionprofile"
    out.write_bytes(base64.b64decode(content_b64))
    sys.stderr.write(f"==> Installed profile → {out}\n")


def main() -> None:
    key_id, issuer_id, p8_path = load_env()
    sys.stderr.write(f"Auth: Key {key_id}  Issuer {issuer_id}\n")
    token = make_jwt(key_id, issuer_id, p8_path)

    # App-binary cert (Apple Distribution). Skips silently if both
    # Apple-side and local keychain already have it.
    result = find_or_create_distribution_cert(token)
    if result is not None:
        cert_id, cert_der, private_key = result
        install_cert_in_keychain(cert_der, private_key, "Apple Distribution")
        sys.stderr.write(f"==> Apple Distribution cert id={cert_id}\n")
    # Look up the cert ID at Apple for the profile relationship below.
    dist_certs = api(token, "GET", "certificates?filter[certificateType]=DISTRIBUTION")
    cert_id = dist_certs["data"][0]["id"]

    # Installer-package cert (Mac Installer Distribution). Required to
    # sign the .pkg that Xcode produces for Mac App Store uploads; the
    # Apple Distribution cert above only signs the .app inside.
    result = mint_cert(token, "MAC_INSTALLER_DISTRIBUTION", "Mac Installer Distribution")
    if result is not None:
        installer_id, installer_der, installer_key = result
        install_cert_in_keychain(installer_der, installer_key, "Mac Installer Distribution")
        sys.stderr.write(f"==> Mac Installer Distribution cert id={installer_id}\n")
    installer_certs = api(
        token, "GET",
        "certificates?filter[certificateType]=MAC_INSTALLER_DISTRIBUTION",
    )
    installer_id = installer_certs["data"][0]["id"]

    bundle_id = find_bundle_id(token, BUNDLE_ID_IDENT)
    sys.stderr.write(f"==> Bundle ID resource: {bundle_id}\n")

    profile = create_mac_app_store_profile(
        token, bundle_id, [cert_id, installer_id]
    )
    install_profile(profile)

    sys.stderr.write("\nDone. Next: bash scripts/upload-appstore.sh\n")


if __name__ == "__main__":
    main()
