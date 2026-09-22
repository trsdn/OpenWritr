import hashlib
import json
import pathlib
import tempfile
import unittest

import verify_broker_artifacts


class VerifyBrokerArtifactsTests(unittest.TestCase):
    def create_fixture(self, root: pathlib.Path, tag: str = "v1.2.3") -> None:
        version = tag.removeprefix("v")
        names = [
            f"OpenWritr-v{version}-macOS-arm64.zip",
            f"OpenWritr-v{version}-macOS-arm64.dmg",
            f"OpenWritr-{version}.dmg",
        ]
        contents = {
            names[0]: b"zip",
            names[1]: b"dmg",
            names[2]: b"dmg",
        }
        artifacts = []
        for name in names:
            path = root / name
            path.write_bytes(contents[name])
            digest = hashlib.sha256(contents[name]).hexdigest()
            checksum = f"{name}.sha256"
            (root / checksum).write_text(f"{digest}  {name}\n", encoding="utf-8")
            artifacts.append(
                {
                    "name": name,
                    "checksum": checksum,
                    "sha256": digest,
                    "attest": name.endswith(".zip"),
                }
            )
        zip_name = names[0]
        zip_digest = hashlib.sha256(contents[zip_name]).hexdigest()
        (root / "attestation-subjects.sha256").write_text(
            f"{zip_digest}  {zip_name}\n",
            encoding="utf-8",
        )
        profile_digest = "b" * 64
        (root / "preflight-manifest.json").write_text(
            json.dumps(
                {
                    "profile": "openwritr",
                    "version": version,
                    "profile_digest": profile_digest,
                }
            ),
            encoding="utf-8",
        )
        (root / "provenance.json").write_text(
            json.dumps(
                {
                    "profile": "openwritr",
                    "profile_digest": profile_digest,
                    "request_id": "req-test",
                    "version": version,
                    "broker": {
                        "repository": "trsdn/macos-notarization-broker",
                        "commit_sha": "c" * 40,
                        "run_id": "12345",
                        "run_attempt": "1",
                    },
                    "source": {
                        "repository": "trsdn/OpenWritr",
                        "repository_id": 1165782217,
                        "tag": tag,
                        "ref_target_sha": "a" * 40,
                        "tag_object_sha": None,
                        "commit_sha": "a" * 40,
                    },
                    "signed_application": {
                        "bundle_identifier": "com.openwritr.app",
                        "team_id": "G69Z5BNY97",
                    },
                    "artifacts": artifacts,
                }
            ),
            encoding="utf-8",
        )

    def test_accepts_exact_openwritr_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.create_fixture(root)
            self.assertEqual(verify_broker_artifacts.verify_artifacts(root, "v1.2.3"), "a" * 40)

    def test_rejects_non_identical_updater_alias(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.create_fixture(root)
            alias = root / "OpenWritr-1.2.3.dmg"
            alias.write_bytes(b"different")
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                verify_broker_artifacts.verify_artifacts(root, "v1.2.3")

    def test_rejects_wrong_developer_id_team(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.create_fixture(root)
            provenance_path = root / "provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["signed_application"]["team_id"] = "ATTACKER00"
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Developer ID team"):
                verify_broker_artifacts.verify_artifacts(root, "v1.2.3")

    def test_rejects_noncanonical_checksum_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.create_fixture(root)
            provenance_path = root / "provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            artifact = provenance["artifacts"][0]
            alternate_checksum = "alternate-safe-name.sha256"
            (root / alternate_checksum).write_text(
                f"{artifact['sha256']}  {artifact['name']}\n",
                encoding="utf-8",
            )
            artifact["checksum"] = alternate_checksum
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "checksum name is not canonical"):
                verify_broker_artifacts.verify_artifacts(root, "v1.2.3")

    def test_rejects_dmg_attestation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            self.create_fixture(root)
            provenance_path = root / "provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["artifacts"][1]["attest"] = True
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "attestation policy"):
                verify_broker_artifacts.verify_artifacts(root, "v1.2.3")


if __name__ == "__main__":
    unittest.main()
