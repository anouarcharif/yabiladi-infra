import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import bootstrap_onboarding


class FakeApi:
    def __init__(self):
        self.keys = []
        self.calls = []
        self.next_key = 0

    def __call__(self, endpoint, payload, jwt=None):
        self.calls.append((endpoint, payload, jwt))
        if endpoint == "/auth/login/LoginLocalUser":
            return {"type": "Jwt", "data": {"jwt": "admin-jwt"}}
        if endpoint == "/read/ListOnboardingKeys":
            return list(self.keys)
        if endpoint == "/write/CreateOnboardingKey":
            private_key = payload["private_key"]
            if private_key is None:
                self.next_key += 1
                private_key = f"private-{self.next_key}"
            public_key = f"public-{private_key}"
            key = {
                "public_key": public_key,
                "enabled": True,
                "privileged": payload["privileged"],
                "expires": payload["expires"],
            }
            self.keys.append(key)
            return {"private_key": private_key, "created": key}
        if endpoint == "/write/UpdateOnboardingKey":
            key = next(
                item for item in self.keys
                if item["public_key"] == payload["public_key"]
            )
            key.update(payload)
            return key
        raise AssertionError(f"Unexpected API endpoint: {endpoint}")


class BootstrapOnboardingTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.key_path = Path(self.temp_dir.name) / "onboarding.key"
        self.public_path = Path(self.temp_dir.name) / "onboarding.pub"
        self.api = FakeApi()

    def ensure_key(self):
        return bootstrap_onboarding.ensure_onboarding_key(
            "http://komodo",
            "admin",
            "password",
            "Yabiladi Tarourt",
            self.key_path,
            self.public_path,
            self.api,
        )

    def test_creates_and_persists_key_pair(self):
        self.assertEqual(self.ensure_key(), "created")
        self.assertEqual(self.key_path.read_text().strip(), "private-1")
        self.assertEqual(self.public_path.read_text().strip(), "public-private-1")
        self.assertEqual(len(self.api.keys), 1)
        if os.name == "posix":
            self.assertEqual(stat.S_IMODE(self.key_path.stat().st_mode), 0o600)

    def test_default_api_uses_core_address(self):
        create_response = {
            "private_key": "private-1",
            "created": {"public_key": "public-private-1"},
        }
        with patch.object(
            bootstrap_onboarding,
            "post_json",
            side_effect=[
                {"type": "Jwt", "data": {"jwt": "admin-jwt"}},
                [],
                create_response,
            ],
        ) as post_json:
            status = bootstrap_onboarding.ensure_onboarding_key(
                "http://komodo",
                "admin",
                "password",
                "Yabiladi Tarourt",
                self.key_path,
                self.public_path,
            )

        self.assertEqual(status, "created")
        self.assertEqual(
            post_json.call_args_list[0],
            call(
                "http://komodo",
                "/auth/login/LoginLocalUser",
                {"username": "admin", "password": "password"},
                None,
            ),
        )

    def test_reuses_enabled_key_on_redeployment(self):
        self.ensure_key()
        self.api.calls.clear()

        self.assertEqual(self.ensure_key(), "ready")
        self.assertFalse(
            any(call[0] == "/write/CreateOnboardingKey" for call in self.api.calls)
        )

    def test_recreates_revoked_key_with_same_private_key(self):
        self.ensure_key()
        self.api.keys.clear()
        self.api.calls.clear()

        self.assertEqual(self.ensure_key(), "created")
        create = next(
            call for call in self.api.calls
            if call[0] == "/write/CreateOnboardingKey"
        )
        self.assertEqual(create[1]["private_key"], "private-1")
        self.assertEqual(len(self.api.keys), 1)

    def test_restores_privileged_enabled_nonexpiring_key(self):
        self.ensure_key()
        self.api.keys[0].update(
            {"enabled": False, "privileged": False, "expires": 123}
        )

        self.assertEqual(self.ensure_key(), "ready")
        self.assertTrue(self.api.keys[0]["enabled"])
        self.assertTrue(self.api.keys[0]["privileged"])
        self.assertEqual(self.api.keys[0]["expires"], 0)


if __name__ == "__main__":
    unittest.main()
