"""Install the checksum-pinned scanner into an ignored project directory."""

import hashlib
import platform
import tarfile
from pathlib import Path

from collect_resources import download

VERSION = "8.30.1"
HASHES = {
    ("Darwin", "arm64"): (
        "darwin_arm64",
        "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5",
    ),
    ("Linux", "x86_64"): (
        "linux_x64",
        "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb",
    ),
}


def main():
    target = Path(__file__).resolve().parents[2] / "artifacts/tools"
    target.mkdir(parents=True, exist_ok=True)
    arch, checksum = HASHES[(platform.system(), platform.machine())]
    name = f"gitleaks_{VERSION}_{arch}.tar.gz"
    archive = target / name
    if (
        not archive.is_file()
        or hashlib.sha256(archive.read_bytes()).hexdigest() != checksum
    ):
        download(
            f"https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/{name}",
            archive,
        )
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise RuntimeError("Scanner checksum mismatch")
    with tarfile.open(archive) as source:
        info = source.getmember("gitleaks")
        if not info.isfile():
            raise RuntimeError("Unexpected scanner archive member")
        with source.extractfile(info) as stream:
            (target / "gitleaks").write_bytes(stream.read())
    (target / "gitleaks").chmod(0o755)
    print(target / "gitleaks")


if __name__ == "__main__":
    main()
