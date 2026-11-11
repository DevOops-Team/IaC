"""Native OpenSSH jump connection with pinned pfSense host-key verification."""

import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    request = json.load(sys.stdin)
    config = request["config"]
    host = config["pfSenseHost"]
    jump = config["jumpHost"]
    if not re.fullmatch(r"[0-9.]+", host) or not re.fullmatch(r"[A-Za-z0-9_.-]+", jump):
        raise ValueError("Invalid pfSense or jump host.")
    if request["operation"] not in ("check", "configure", "disable"):
        raise ValueError("Unknown pfSense operation.")
    source = Path(__file__).with_name("vpn.php").read_text(encoding="utf-8")
    payload = base64.b64encode(json.dumps(request).encode()).decode()
    source = source.replace("__REQUEST__", payload)
    options = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10"]
    scan = subprocess.run(["ssh", *options, jump,
                           "ssh-keyscan -T 5 -t ed25519 " + host + " 2>/dev/null"],
                          capture_output=True, text=True, timeout=25)
    keys = [line for line in scan.stdout.splitlines() if line.startswith(host + " ssh-ed25519 ")]
    if scan.returncode or len(keys) != 1:
        raise RuntimeError("Cannot obtain the pfSense public host key through the trusted jump host.")
    digest = base64.b64encode(hashlib.sha256(base64.b64decode(keys[0].split()[2])).digest()).decode().rstrip("=")
    if "SHA256:" + digest != config["pfSenseHostKeyFingerprint"]:
        raise RuntimeError("pfSense SSH host key differs from the configured fingerprint.")
    # The temporary file contains only a public host key. Secrets use SSH stdin.
    with tempfile.TemporaryDirectory(prefix="devoops-ssh-") as directory:
        hosts = Path(directory) / "known_hosts"
        hosts.write_text(keys[0] + "\n", encoding="ascii")
        result = subprocess.run(["ssh", *options, "-J", jump,
                                 "-o", "HostKeyAlgorithms=ssh-ed25519",
                                 "-o", "UserKnownHostsFile=" + str(hosts),
                                 "-o", "IdentitiesOnly=yes", "-i", str(Path(config["sshIdentityFile"]).expanduser()),
                                 "root@" + host, "php"],
                                input=source, capture_output=True, text=True, encoding="utf-8", timeout=150)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "pfSense operation failed.")
    print(json.dumps(json.loads(result.stdout)))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
