#!/usr/bin/env python3

import argparse
import hashlib
import json
import pathlib
import re


REPOSITORY = "trsdn/OpenWritr"
REPOSITORY_ID = 1165782217
BROKER_REPOSITORY = "trsdn/macos-notarization-broker"
BUNDLE_IDENTIFIER = "com.openwritr.app"
TEAM_ID = "G69Z5BNY97"


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_artifacts(root: pathlib.Path, tag: str) -> str:
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", tag):
        raise ValueError(f"Tag must be an exact version tag such as v1.2.3: {tag}")
    if not root.is_dir():
        raise ValueError(f"Broker artifact directory does not exist: {root}")

    version = tag.removeprefix("v")
    provenance_path = root / "provenance.json"
    manifest_path = root / "preflight-manifest.json"
    if not provenance_path.is_file() or provenance_path.is_symlink():
        raise ValueError("Broker artifact is missing a regular provenance.json")
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise ValueError("Broker artifact is missing a regular preflight-manifest.json")

    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    if provenance.get("profile") != "openwritr":
        raise ValueError("Broker provenance profile is not openwritr")
    if provenance.get("version") != version:
        raise ValueError("Broker provenance names the wrong version")
    profile_digest = provenance.get("profile_digest", "")
    if not re.fullmatch(r"[0-9a-f]{64}", profile_digest):
        raise ValueError("Broker provenance has no valid profile digest")
    request_id = provenance.get("request_id", "")
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", request_id):
        raise ValueError("Broker provenance has no valid request ID")

    broker = provenance.get("broker", {})
    if broker.get("repository") != BROKER_REPOSITORY:
        raise ValueError("Broker provenance names the wrong broker repository")
    if not re.fullmatch(r"[0-9a-f]{40}", broker.get("commit_sha", "")):
        raise ValueError("Broker provenance has no immutable broker commit")
    if not str(broker.get("run_id", "")).isdigit():
        raise ValueError("Broker provenance has no valid workflow run ID")
    if not str(broker.get("run_attempt", "")).isdigit() or int(broker["run_attempt"]) < 1:
        raise ValueError("Broker provenance has no valid workflow run attempt")

    source = provenance.get("source", {})
    if source.get("repository") != REPOSITORY:
        raise ValueError("Broker provenance names the wrong source repository")
    if source.get("repository_id") != REPOSITORY_ID:
        raise ValueError("Broker provenance names the wrong source repository ID")
    if source.get("tag") != tag:
        raise ValueError("Broker provenance names the wrong source tag")
    commit_sha = source.get("commit_sha", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit_sha):
        raise ValueError("Broker provenance has no immutable source commit")
    if not re.fullmatch(r"[0-9a-f]{40}", source.get("ref_target_sha", "")):
        raise ValueError("Broker provenance has no immutable source ref target")
    tag_object_sha = source.get("tag_object_sha")
    if tag_object_sha is not None and not re.fullmatch(r"[0-9a-f]{40}", tag_object_sha):
        raise ValueError("Broker provenance has an invalid tag object SHA")

    signed_application = provenance.get("signed_application", {})
    if signed_application.get("bundle_identifier") != BUNDLE_IDENTIFIER:
        raise ValueError("Broker provenance names the wrong bundle identifier")
    if signed_application.get("team_id") != TEAM_ID:
        raise ValueError("Broker provenance names the wrong Developer ID team")

    preflight = json.loads(manifest_path.read_text(encoding="utf-8"))
    if (
        preflight.get("profile") != "openwritr"
        or preflight.get("version") != version
        or preflight.get("profile_digest") != profile_digest
    ):
        raise ValueError("Preflight manifest does not match the broker provenance")

    expected = {
        f"OpenWritr-v{version}-macOS-arm64.zip",
        f"OpenWritr-v{version}-macOS-arm64.dmg",
        f"OpenWritr-{version}.dmg",
    }
    expected_attestation = {f"OpenWritr-v{version}-macOS-arm64.zip"}
    artifacts = provenance.get("artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("Broker provenance has no artifact list")
    by_name = {artifact.get("name"): artifact for artifact in artifacts}
    if len(artifacts) != len(expected) or set(by_name) != expected:
        raise ValueError(
            "Broker provenance artifact contract differs from OpenWritr's expected ZIP, DMG, and updater alias"
        )

    for name, artifact in by_name.items():
        if artifact.get("attest") != (name in expected_attestation):
            raise ValueError(f"Broker attestation policy is unsafe for OpenWritr: {name}")
        path = root / name
        checksum_name = artifact.get("checksum")
        if (
            not isinstance(checksum_name, str)
            or pathlib.PurePath(checksum_name).name != checksum_name
        ):
            raise ValueError(f"Broker checksum name is unsafe: {checksum_name}")
        expected_checksum_name = f"{name}.sha256"
        if checksum_name != expected_checksum_name:
            raise ValueError(
                f"Broker checksum name is not canonical for {name}: "
                f"expected {expected_checksum_name}, got {checksum_name}"
            )
        checksum_path = root / str(checksum_name)
        if (
            not path.is_file()
            or path.is_symlink()
            or not checksum_path.is_file()
            or checksum_path.is_symlink()
        ):
            raise ValueError(f"Broker artifact or checksum is missing or unsafe: {name}")
        digest = sha256(path)
        if digest != artifact.get("sha256"):
            raise ValueError(f"Broker provenance digest mismatch: {name}")
        checksum_fields = checksum_path.read_text(encoding="utf-8").strip().split()
        if len(checksum_fields) != 2 or checksum_fields[0] != digest:
            raise ValueError(f"Broker checksum content mismatch: {checksum_path.name}")
        if checksum_fields[1] not in {name, f"*{name}"}:
            raise ValueError(f"Broker checksum names the wrong file: {checksum_path.name}")

    primary = root / f"OpenWritr-v{version}-macOS-arm64.dmg"
    updater = root / f"OpenWritr-{version}.dmg"
    if sha256(primary) != sha256(updater):
        raise ValueError("AppUpdater alias is not byte-identical to the versioned DMG")

    attestation_manifest = root / "attestation-subjects.sha256"
    if not attestation_manifest.is_file() or attestation_manifest.is_symlink():
        raise ValueError("Broker artifact is missing a regular attestation subject manifest")
    expected_zip = root / f"OpenWritr-v{version}-macOS-arm64.zip"
    expected_line = f"{sha256(expected_zip)}  {expected_zip.name}"
    lines = attestation_manifest.read_text(encoding="utf-8").splitlines()
    if lines != [expected_line]:
        raise ValueError("Broker attestation subject manifest must contain only the OpenWritr ZIP")

    return commit_sha


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact_directory", type=pathlib.Path)
    parser.add_argument("tag")
    args = parser.parse_args()
    print(verify_artifacts(args.artifact_directory, args.tag))


if __name__ == "__main__":
    main()
