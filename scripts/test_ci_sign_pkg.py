#!/usr/bin/env python3
"""Exercise CI credential cleanup without real certificates or Apple services."""
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SECRET_NAMES = (
    "MACOS_SIGNING_P12_BASE64", "MACOS_INSTALLER_P12_BASE64",
    "MACOS_SIGNING_P12_PASSWORD", "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD",
)

# Tool doubles validate the trust boundary, not Apple's signing implementation.
TOOL = r'''
import json, os, pathlib, stat, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
op = args[0] if args else ''
if name == 'xcrun':
    op = args[1] if len(args) > 1 else ''
with open(os.environ['AUDIT_FILE'], 'a') as out:
    out.write(json.dumps([name, op]) + '\n')
if name in ('xcodebuild', 'xcodegen'):
    sys.exit('A build must never run on the signing runner')
if name == 'security':
    if op == 'list-keychains' and '-s' not in args:
        print('    "/original path/login.keychain-db"')
    elif op == 'list-keychains' and '-s' in args:
        assert args[-1] == '/original path/login.keychain-db'
    elif op == 'create-keychain':
        pathlib.Path(args[-1]).touch(mode=0o600)
    elif op == 'import':
        assert '-x' in args
        assert '/usr/bin/security' not in args
        path = pathlib.Path(args[1])
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
    elif op == 'delete-keychain':
        if os.environ.get('FAIL_AT') == 'cleanup':
            sys.exit(42)
        pathlib.Path(args[-1]).unlink()
if name in ('codesign', 'pkgbuild', 'productsign') or (name == 'xcrun' and op == 'submit'):
    for key in ('MACOS_SIGNING_P12_BASE64', 'MACOS_INSTALLER_P12_BASE64',
                'MACOS_SIGNING_P12_PASSWORD', 'APPLE_ID',
                'APPLE_APP_SPECIFIC_PASSWORD', 'KC_PASSWORD', 'KEYCHAIN_PASS_FILE'):
        assert key not in os.environ, key + ' leaked to a signing subprocess'
    kc = pathlib.Path(os.environ['CODESIGN_KEYCHAIN'])
    assert kc.is_file()
    assert not list(kc.parent.glob('*.p12'))
failure = os.environ.get('FAIL_AT')
if failure and (failure == name or failure == name + ':' + op):
    sys.exit(42)
if name == 'ditto' or name == 'pkgbuild':
    pathlib.Path(args[-1]).touch()
if name == 'productsign':
    pathlib.Path(args[-1]).write_bytes(pathlib.Path(args[-2]).read_bytes())
'''


class SigningBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="glotty-sign-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("ci-sign-pkg.sh", "make-pkg-signed.sh"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        app = self.root / "unsigned app" / "Glotty.app" / "Contents"
        app.mkdir(parents=True)
        with (app / "Info.plist").open("wb") as out:
            plistlib.dump({"CFBundleShortVersionString": "1.0.9"}, out)
        self.runner_temp = self.root / "runner temp"
        self.runner_temp.mkdir()
        tools = self.root / "bin"
        tools.mkdir()
        for name in ("security", "xcrun", "codesign", "pkgbuild", "productsign",
                     "ditto", "spctl", "pkgutil", "xcodebuild", "xcodegen"):
            path = tools / name
            path.write_text("#!" + sys.executable + "\n" + TOOL)
            path.chmod(0o700)
        self.env = {
            "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "HOME": str(self.root), "RUNNER_TEMP": str(self.runner_temp),
            "PREBUILT_APP_PATH": str(app.parent),
            "AUDIT_FILE": str(self.root / "audit.jsonl"),
            "MACOS_SIGNING_P12_BASE64": base64.b64encode(b"fake-app-p12").decode(),
            "MACOS_INSTALLER_P12_BASE64": base64.b64encode(b"fake-installer-p12").decode(),
            "MACOS_SIGNING_P12_PASSWORD": "fake-p12-password",
            "APPLE_ID": "fake-apple-id@example.invalid",
            "APPLE_APP_SPECIFIC_PASSWORD": "fake-notary-password",
            # Simulate a stale legacy runner setting; CI must not use it.
            "KEYCHAIN_PASS_FILE": "/must-not-be-read",
        }

    def run_signing(self, failure=None):
        env = dict(self.env)
        Path(env["AUDIT_FILE"]).unlink(missing_ok=True)
        if failure:
            env["FAIL_AT"] = failure
        result = subprocess.run(
            ["/bin/bash", str(self.root / "scripts/ci-sign-pkg.sh")],
            cwd=self.root, env=env, text=True, capture_output=True, timeout=30,
        )
        for key in SECRET_NAMES:
            if key in env:
                self.assertNotIn(env[key], result.stdout + result.stderr)
        self.assertEqual(list(self.runner_temp.iterdir()), [])
        self.assertFalse((self.runner_temp / "glotty-kc-pass").exists())
        return result

    def test_success_cleans_credentials_and_never_builds(self):
        result = self.run_signing()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in Path(self.env["AUDIT_FILE"]).read_text().splitlines()]
        self.assertIn(["security", "delete-keychain"], calls)
        self.assertEqual(len(list((self.root / "dist").glob("*.pkg"))), 1)
        self.assertTrue((Path(self.env["PREBUILT_APP_PATH"]) / "Contents/Info.plist").exists())

    def test_failures_still_clean_credentials(self):
        for failure in ("security:import", "xcrun:store-credentials", "codesign",
                        "pkgbuild", "productsign", "xcrun:submit", "cleanup"):
            with self.subTest(failure=failure):
                result = self.run_signing(failure)
                self.assertNotEqual(result.returncode, 0)
                calls = Path(self.env["AUDIT_FILE"]).read_text()
                self.assertIn('["security", "delete-keychain"]', calls)

    def test_missing_credentials_fail_before_creating_keychain(self):
        for key in SECRET_NAMES:
            with self.subTest(key=key):
                original = self.env.pop(key)
                try:
                    result = self.run_signing()
                finally:
                    self.env[key] = original
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(Path(self.env["AUDIT_FILE"]).exists())


if __name__ == "__main__":
    unittest.main()
