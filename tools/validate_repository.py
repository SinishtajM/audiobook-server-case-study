#!/usr/bin/env python3
"""Validate repository structure, documentation links, and public sanitization."""

from __future__ import annotations

import ipaddress
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]

REQUIRED_FILES = {
    Path("README.md"),
    Path("LICENSE"),
    Path("NOTICE.md"),
    Path(".gitignore"),
    Path(".github/workflows/repository-validation.yml"),
    Path("scripts/README.md"),
    Path("scripts/server-health.example.sh"),
    Path("scripts/backup-audiobooks-local.example.sh"),
    Path("scripts/backup-health.example.sh"),
    Path("tools/validate_repository.py"),
    Path("tools/image_audit.py"),
}

PROHIBITED_EXACT_NAMES = {
    ".env",
    "id_rsa",
    "id_ed25519",
    "known_hosts",
}
PROHIBITED_SUFFIXES = {
    ".pem",
    ".key",
    ".p12",
    ".pfx",
    ".kdbx",
    ".ovpn",
    ".torrent",
    ".aa",
    ".aax",
    ".aac",
    ".flac",
    ".m4a",
    ".m4b",
    ".mp3",
    ".ogg",
    ".opus",
    ".wav",
}
ALLOWED_IMAGE_DIRECTORIES = {Path("screenshots"), Path("diagrams")}
CGNAT_NETWORK = ipaddress.ip_network("100." + "64.0.0/10")

IPV4_CANDIDATE = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
IPV6_CANDIDATE = re.compile(r"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])")
ABSOLUTE_HOME_PATH = re.compile(r"(?<![\w.-])/(?:home|Users)/[^/\s]+(?:/[^\s]*)?")
LIVE_MOUNT_PATH = re.compile(r"(?<![\w.-])/mnt/[A-Za-z0-9._/-]+")
SHELL_PROMPT = re.compile(r"(?m)^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+(?=[:$#])")
MAGNET_URI = re.compile(r"magnet" + re.escape(":?xt=urn:btih:"), re.IGNORECASE)

SECRET_PATTERNS = (
    ("private key material", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b")),
    ("AWS access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("OpenAI-style secret key", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b")),
    (
        "credential assignment",
        re.compile(
            r"(?i)\b(?:password|passwd|token|secret|api[_-]?key|private[_-]?key)\b"
            r"\s*[:=]\s*['\"]?(?!<|\$\{|REDACTED|CHANGE_ME|EXAMPLE|example)"
            r"[A-Za-z0-9+/_=-]{8,}"
        ),
    ),
)

FENCED_CODE = re.compile(r"```.*?```", re.DOTALL)
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*$", re.MULTILINE)

README_REQUIRED_PHRASES = (
    "Public-domain audiobook recordings obtained from Internet Archive",
    "Audiobooks purchased and owned by the project operator through Audible",
    "It is not used to obtain unauthorized copies of copyrighted audiobooks",
    "SLEEPTIME=10m",
    "MAKE_BACKUP=N",
    "Only `Audiobooks` is treated as production data",
    "it is not an off-site disaster-recovery solution",
)


def tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return [ROOT / item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def read_text(path: Path) -> str | None:
    try:
        data = path.read_bytes()
    except OSError as exc:
        return f"__READ_ERROR__:{exc}"
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def relative(path: Path) -> Path:
    return path.relative_to(ROOT)


def check_required_files(files: list[Path]) -> list[str]:
    tracked = {relative(path) for path in files}
    return [f"Required repository file is missing: {path}" for path in sorted(REQUIRED_FILES - tracked)]


def check_prohibited_filenames(files: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in files:
        rel = relative(path)
        name = path.name.lower()
        suffix = path.suffix.lower()
        if name in PROHIBITED_EXACT_NAMES or name.startswith(".env"):
            errors.append(f"Prohibited sensitive filename is tracked: {rel}")
        if suffix in PROHIBITED_SUFFIXES:
            errors.append(f"Prohibited credential, torrent, or audiobook file is tracked: {rel}")
        if name.startswith(("credentials", "service-account")) and suffix == ".json":
            errors.append(f"Credential file is tracked: {rel}")
        if suffix in {".png", ".jpg", ".jpeg", ".webp"} and rel.parent not in ALLOWED_IMAGE_DIRECTORIES:
            errors.append(f"Image is outside an approved evidence directory: {rel}")
    return errors


def check_ip_address(token: str) -> bool:
    try:
        address = ipaddress.ip_address(token)
    except ValueError:
        return False
    if address.is_loopback:
        return False
    if isinstance(address, ipaddress.IPv4Address) and address in CGNAT_NETWORK:
        return True
    return address.is_private or address.is_link_local


def check_sensitive_content(files: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in files:
        text = read_text(path)
        if text is None:
            continue
        rel = relative(path)
        if text.startswith("__READ_ERROR__:"):
            errors.append(f"Could not read {rel}: {text.removeprefix('__READ_ERROR__:')}")
            continue

        for line_number, line in enumerate(text.splitlines(), start=1):
            for match in IPV4_CANDIDATE.finditer(line):
                if check_ip_address(match.group(0)):
                    errors.append(f"Private or link-local IPv4 address found in {rel}:{line_number}")
            for match in IPV6_CANDIDATE.finditer(line):
                if check_ip_address(match.group(0)):
                    errors.append(f"Private or link-local IPv6 address found in {rel}:{line_number}")
            if ABSOLUTE_HOME_PATH.search(line):
                errors.append(f"Absolute user-home path found in {rel}:{line_number}")
            if LIVE_MOUNT_PATH.search(line):
                errors.append(f"Potential live /mnt path found in {rel}:{line_number}")
            if SHELL_PROMPT.search(line):
                errors.append(f"Possible username and hostname shell prompt found in {rel}:{line_number}")
            if MAGNET_URI.search(line):
                errors.append(f"Magnet URI found in {rel}:{line_number}")
            for label, pattern in SECRET_PATTERNS:
                if pattern.search(line):
                    errors.append(f"Possible {label} found in {rel}:{line_number}")
    return errors


def normalize_link_target(raw_target: str) -> str:
    target = raw_target.strip()
    if target.startswith("<") and ">" in target:
        target = target[1 : target.index(">")]
    elif " " in target:
        target = target.split(" ", 1)[0]
    return unquote(target)


def github_slug(title: str) -> str:
    title = re.sub(r"<[^>]+>", "", title)
    title = title.strip().lower()
    title = re.sub(r"[^\w\s-]", "", title, flags=re.UNICODE)
    title = re.sub(r"\s+", "-", title)
    title = re.sub(r"-+", "-", title)
    return title.strip("-")


def document_anchors(text: str) -> set[str]:
    anchors: set[str] = set()
    counts: Counter[str] = Counter()
    for match in HEADING.finditer(FENCED_CODE.sub("", text)):
        base = github_slug(match.group(2))
        suffix = counts[base]
        counts[base] += 1
        anchors.add(base if suffix == 0 else f"{base}-{suffix}")
    return anchors


def check_markdown_links(files: list[Path]) -> list[str]:
    errors: list[str] = []
    markdown_files = [path for path in files if path.suffix.lower() == ".md"]
    text_cache: dict[Path, str] = {}
    anchor_cache: dict[Path, set[str]] = {}

    for document in markdown_files:
        text = read_text(document)
        if text is None or text.startswith("__READ_ERROR__:"):
            continue
        text_cache[document] = text
        anchor_cache[document] = document_anchors(text)

    for document, text in text_cache.items():
        searchable = FENCED_CODE.sub("", text)
        for match in MARKDOWN_LINK.finditer(searchable):
            target = normalize_link_target(match.group(1))
            if not target or target.startswith(("http://", "https://", "mailto:")):
                continue

            path_part, separator, anchor = target.partition("#")
            target_document = document if not path_part else (document.parent / path_part).resolve()
            try:
                target_document.relative_to(ROOT)
            except ValueError:
                errors.append(f"Local link escapes the repository in {relative(document)}: {target}")
                continue

            if path_part and not target_document.exists():
                errors.append(f"Missing local link target in {relative(document)}: {path_part}")
                continue
            if separator and anchor:
                markdown_target = target_document if target_document.suffix.lower() == ".md" else None
                if markdown_target and markdown_target in anchor_cache and anchor not in anchor_cache[markdown_target]:
                    errors.append(f"Missing Markdown anchor in {relative(document)}: {target}")
    return errors


def check_image_references(files: list[Path]) -> list[str]:
    errors: list[str] = []
    readme = ROOT / "README.md"
    text = read_text(readme)
    if text is None or text.startswith("__READ_ERROR__:"):
        return ["README.md could not be read for image-reference validation"]

    referenced: set[Path] = set()
    for match in MARKDOWN_LINK.finditer(FENCED_CODE.sub("", text)):
        target = normalize_link_target(match.group(1)).split("#", 1)[0].split("?", 1)[0]
        if target and not target.startswith(("http://", "https://")):
            candidate = (readme.parent / target).resolve()
            if candidate.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}:
                referenced.add(candidate)

    tracked_images = {
        path.resolve()
        for path in files
        if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".webp"}
    }
    for image in sorted(tracked_images - referenced):
        errors.append(f"Tracked image is not referenced in README.md: {relative(image)}")
    return errors


def check_text_hygiene(files: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in files:
        text = read_text(path)
        if text is None or text.startswith("__READ_ERROR__:"):
            continue
        rel = relative(path)
        if "\r\n" in text:
            errors.append(f"CRLF line endings found in {rel}")
        if text and not text.endswith("\n"):
            errors.append(f"Text file does not end with a newline: {rel}")
        for line_number, line in enumerate(text.splitlines(), start=1):
            if line.rstrip(" \t") != line:
                errors.append(f"Trailing whitespace found in {rel}:{line_number}")
    return errors


def check_readme_invariants() -> list[str]:
    text = read_text(ROOT / "README.md")
    if text is None or text.startswith("__READ_ERROR__:"):
        return ["README.md could not be read for content validation"]
    errors = [
        f"README.md is missing required statement: {phrase}"
        for phrase in README_REQUIRED_PHRASES
        if phrase not in text
    ]
    if "[License](#license)" not in text:
        errors.append("README.md table of contents is missing the License entry")
    if "## License" not in text or "NOTICE.md" not in text or "LICENSE" not in text:
        errors.append("README.md is missing the license-scope section")
    return errors


def main() -> int:
    files = tracked_files()
    errors: list[str] = []
    errors.extend(check_required_files(files))
    errors.extend(check_prohibited_filenames(files))
    errors.extend(check_sensitive_content(files))
    errors.extend(check_markdown_links(files))
    errors.extend(check_image_references(files))
    errors.extend(check_text_hygiene(files))
    errors.extend(check_readme_invariants())

    if errors:
        print("Repository validation failed:", file=sys.stderr)
        for error in sorted(set(errors)):
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"Repository validation passed for {len(files)} tracked files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
