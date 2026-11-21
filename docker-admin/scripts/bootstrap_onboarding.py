#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


class BootstrapError(Exception):
    pass


class CoreUnavailable(BootstrapError):
    pass


def restrict_file_permissions(path):
    if os.name == "nt":
        try:
            account = subprocess.run(
                ["whoami"],
                check=True,
                capture_output=True,
                text=True,
                encoding="mbcs",
                errors="replace",
            ).stdout.strip()
            result = subprocess.run(
                [
                    "icacls",
                    str(path),
                    "/inheritance:r",
                    "/remove",
                    "*S-1-1-0",
                    "*S-1-5-11",
                    "*S-1-5-32-545",
                    "*S-1-5-32-546",
                    "*S-1-5-18",
                    "*S-1-5-32-544",
                    "/grant:r",
                    f"{account}:(R,W)",
                ],
                capture_output=True,
                text=True,
                encoding="mbcs",
                errors="replace",
                check=False,
            )
        except (OSError, subprocess.CalledProcessError) as error:
            raise BootstrapError(
                "Impossible de restreindre les permissions Windows de la clé"
            ) from error
        if result.returncode:
            detail = result.stderr.strip() or result.stdout.strip()
            raise BootstrapError(
                "Impossible de restreindre les permissions Windows de la clé"
                + (f" : {detail}" if detail else "")
            )
    else:
        os.chmod(path, 0o600)


def post_json(address, endpoint, payload, jwt=None):
    headers = {"Content-Type": "application/json"}
    if jwt:
        headers["Authorization"] = jwt
    request = urllib.request.Request(
        address.rstrip("/") + endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        if error.code >= 500:
            raise CoreUnavailable(
                f"Core répond HTTP {error.code} sur {endpoint}"
            ) from None
        raise BootstrapError(
            f"Core refuse {endpoint} (HTTP {error.code})"
        ) from None
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        reason = error.reason if isinstance(error, urllib.error.URLError) else error
        raise CoreUnavailable(f"Core injoignable : {reason}") from None
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BootstrapError(
            f"Réponse JSON invalide de Core sur {endpoint}"
        ) from error


def atomic_write(path, contents):
    path = Path(path)
    if path.is_symlink():
        raise BootstrapError(f"Refus d'écrire une clé via un lien symbolique : {path}")
    if path.exists() and not path.is_file():
        raise BootstrapError(f"Le chemin de clé n'est pas un fichier : {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=str(path.parent)
    )
    try:
        try:
            os.fchmod(descriptor, 0o600)
        except AttributeError:
            pass
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            file.write(contents)
            file.flush()
            os.fsync(file.fileno())
        restrict_file_permissions(temporary)
        os.replace(temporary, path)
    except (OSError, BootstrapError):
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def create_key(api, jwt, name, private_key=None):
    response = api(
        "/write/CreateOnboardingKey",
        {
            "name": name,
            "expires": 0,
            "private_key": private_key,
            "tags": [],
            "privileged": True,
            "copy_server": "",
            "create_builder": False,
        },
        jwt,
    )
    try:
        created = response["created"]
        private_key = response["private_key"]
        public_key = created["public_key"]
    except (KeyError, TypeError) as error:
        raise BootstrapError(
            "Réponse CreateOnboardingKey incomplète"
        ) from error
    if not isinstance(private_key, str) or not private_key:
        raise BootstrapError("Core a retourné une clé privée vide")
    if not isinstance(public_key, str) or not public_key:
        raise BootstrapError("Core a retourné une clé publique vide")
    return private_key, public_key


def ensure_onboarding_key(
    address,
    username,
    password,
    name,
    key_path,
    public_path,
    api=None,
):
    if not username or not password:
        raise BootstrapError(
            "KOMODO_INIT_ADMIN_USERNAME/PASSWORD requis pour l'amorçage automatique"
        )

    if api is None:
        def request(endpoint, payload, jwt=None):
            return post_json(address, endpoint, payload, jwt)
    else:
        request = api

    deadline = time.monotonic() + 180
    while True:
        try:
            login = request(
                "/auth/login/LoginLocalUser",
                {"username": username, "password": password},
            )
            break
        except CoreUnavailable:
            if time.monotonic() >= deadline:
                raise BootstrapError(
                    "Core reste injoignable après 180 secondes"
                ) from None
            time.sleep(5)

    if isinstance(login, dict) and login.get("type") in ("Passkey", "Totp"):
        raise BootstrapError(
            "L'authentification admin exige une étape 2FA non prise en charge par l'amorçage"
        )
    jwt_data = login.get("data") if isinstance(login, dict) else None
    jwt = (
        jwt_data.get("jwt")
        if isinstance(jwt_data, dict) and login.get("type") == "Jwt"
        else None
    )
    if not isinstance(jwt, str) or not jwt:
        raise BootstrapError("Core n'a pas retourné de JWT admin")

    keys = request("/read/ListOnboardingKeys", {}, jwt)
    if not isinstance(keys, list):
        raise BootstrapError("Liste de clés d'onboarding invalide")
    if not all(isinstance(key, dict) for key in keys):
        raise BootstrapError("Entrée invalide dans la liste des clés d'onboarding")

    key_path = Path(key_path)
    public_path = Path(public_path)
    if key_path.is_symlink() or public_path.is_symlink():
        raise BootstrapError("Refus de lire une clé d'onboarding via un lien symbolique")

    if key_path.is_file() and public_path.is_file():
        restrict_file_permissions(key_path)
        private_key = key_path.read_text(encoding="utf-8").strip()
        public_key = public_path.read_text(encoding="utf-8").strip()
        if not private_key or not public_key:
            raise BootstrapError("Fichier local de clé d'onboarding vide")
        existing = next(
            (key for key in keys if key.get("public_key") == public_key),
            None,
        )
        if existing is None:
            new_private_key, new_public_key = create_key(
                request, jwt, name, private_key
            )
            if new_private_key != private_key or new_public_key != public_key:
                raise BootstrapError(
                    "La clé réenregistrée ne correspond pas à la clé locale"
                )
            atomic_write(key_path, private_key + "\n")
            return "created"

        if (
            not existing.get("enabled")
            or not existing.get("privileged")
            or existing.get("expires") != 0
        ):
            updated = request(
                "/write/UpdateOnboardingKey",
                {
                    "public_key": public_key,
                    "enabled": True,
                    "privileged": True,
                    "expires": 0,
                },
                jwt,
            )
            if not isinstance(updated, dict):
                raise BootstrapError("Réponse UpdateOnboardingKey invalide")
            if (
                not updated.get("enabled")
                or not updated.get("privileged")
                or updated.get("expires") != 0
            ):
                raise BootstrapError(
                    "Core n'a pas activé la clé d'onboarding privilégiée"
                )
        return "ready"

    private_key, public_key = create_key(request, jwt, name)
    atomic_write(key_path, private_key + "\n")
    atomic_write(public_path, public_key + "\n")
    return "created"


def main():
    required = (
        "KOMODO_API_ADDRESS",
        "KOMODO_INIT_ADMIN_USERNAME",
        "KOMODO_INIT_ADMIN_PASSWORD",
        "KOMODO_ONBOARDING_KEY_NAME",
        "KOMODO_ONBOARDING_KEY_FILE",
        "KOMODO_ONBOARDING_PUBLIC_KEY_FILE",
    )
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise BootstrapError(
            "Variables requises absentes : " + ", ".join(missing)
        )

    status = ensure_onboarding_key(
        os.environ["KOMODO_API_ADDRESS"],
        os.environ["KOMODO_INIT_ADMIN_USERNAME"],
        os.environ["KOMODO_INIT_ADMIN_PASSWORD"],
        os.environ["KOMODO_ONBOARDING_KEY_NAME"],
        os.environ["KOMODO_ONBOARDING_KEY_FILE"],
        os.environ["KOMODO_ONBOARDING_PUBLIC_KEY_FILE"],
    )
    print(status)


if __name__ == "__main__":
    try:
        main()
    except BootstrapError as error:
        print(f"ERREUR: {error}", file=sys.stderr)
        sys.exit(1)
    except (OSError, UnicodeError) as error:
        print(f"ERREUR: impossible de lire/écrire la clé locale : {error}", file=sys.stderr)
        sys.exit(1)
