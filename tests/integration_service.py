#!/usr/bin/env python3
"""CI only: exercise real systemd restart and rollback in an isolated fixture."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from naive_update import Failure, Service, Transaction, sha256  # noqa: E402


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.geteuid() != 0:
        raise RuntimeError("This integration test runs only as root inside GitHub Actions")
    source = Path(sys.argv[1]).resolve()
    name = "naive-update-ci-" + uuid.uuid4().hex[:12] + ".service"
    unit = Path("/etc/systemd/system") / name
    with tempfile.TemporaryDirectory(prefix="naive-integration-") as directory:
        root = Path(directory)
        binary = root / "caddy"
        validator = root / "original-validator"
        shutil.copy2(source, binary)
        shutil.copy2(source, validator)
        capability = None
        if shutil.which("setcap"):
            subprocess.run(["setcap", "cap_net_bind_service=+ep", binary], check=True)
            capability = os.getxattr(binary, "security.capability")
        config = root / "Caddyfile"
        config.write_text("{\n admin off\n auto_https off\n}\nhttp://127.0.0.1:0 {\n respond ci\n}\n")
        unit.write_text(f"[Unit]\nDescription=Isolated naive-update test\n[Service]\nType=simple\n"
                        f"User=root\nWorkingDirectory={root}\n"
                        f"Environment=XDG_DATA_HOME={root}/data\n"
                        f"Environment=XDG_CONFIG_HOME={root}/config\n"
                        f"ExecStart={binary} run --config {config} --adapter caddyfile\n")
        try:
            subprocess.run(["systemctl", "daemon-reload"], check=True)
            subprocess.run(["systemctl", "start", name], check=True)
            service = Service(name, binary, config)
            service.healthy(sha256(source), seconds=2)
            transaction = Transaction(root / "state", service)
            with transaction.lock():
                transaction.activate(source, {"test": "real-systemd"})
                if capability is not None:
                    assert os.getxattr(binary, "security.capability") == capability
                transaction.rollback()
                broken = root / "broken-caddy"
                broken.write_text("#!/usr/bin/python3\nimport os,sys\n"
                                  "if len(sys.argv)>1 and sys.argv[1]=='validate':\n"
                                  f" os.execv({str(validator)!r}, [{str(validator)!r}]+sys.argv[1:])\n"
                                  "sys.exit(1)\n")
                os.chmod(broken, 0o755)
                failed = False
                try:
                    transaction.activate(broken, {"test": "intentional-restart-failure"})
                except Failure:
                    failed = True
                assert failed, "broken service unexpectedly passed"
                assert sha256(binary) == sha256(source), "old binary was not restored"
                assert not transaction.pending.exists(), "recovery did not finish"
                assert config.read_text().startswith("{\n admin off"), "config was modified"
                service.healthy(sha256(source), seconds=2)
            print("Real systemd install, manual rollback and failed-start recovery passed")
        finally:
            subprocess.run(["systemctl", "stop", name], check=False)
            unit.unlink(missing_ok=True)
            subprocess.run(["systemctl", "daemon-reload"], check=False)


if __name__ == "__main__":
    main()
