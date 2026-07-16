#!/usr/bin/env python3
"""Audit repository PNG files and optionally create metadata-free copies."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import subprocess
import sys
import zlib
from dataclasses import asdict, dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, UnidentifiedImageError

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
SENSITIVE_PNG_CHUNKS = {"tEXt", "zTXt", "iTXt", "eXIf", "tIME"}
IMAGE_SUFFIXES = {".png"}


@dataclass
class ImageResult:
    path: str
    size_bytes: int
    width: int | None
    height: int | None
    mode: str | None
    pixel_sha256: str | None
    chunks: list[str]
    sensitive_chunks: list[str]
    pillow_info_keys: list[str]
    errors: list[str]
    sanitized_path: str | None = None
    sanitized_pixel_sha256: str | None = None
    pixels_match: bool | None = None


def git_tracked_files(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root,
        check=True,
        capture_output=True,
    )
    return [root / item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def parse_png(path: Path) -> tuple[list[str], list[str]]:
    chunks: list[str] = []
    errors: list[str] = []
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        return chunks, ["invalid PNG signature"]

    offset = len(PNG_SIGNATURE)
    saw_ihdr = False
    saw_iend = False
    while offset < len(data):
        if offset + 12 > len(data):
            errors.append("truncated PNG chunk header")
            break
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type_bytes = data[offset + 4 : offset + 8]
        try:
            chunk_type = chunk_type_bytes.decode("ascii")
        except UnicodeDecodeError:
            errors.append("non-ASCII PNG chunk type")
            break
        chunk_end = offset + 12 + length
        if chunk_end > len(data):
            errors.append(f"truncated {chunk_type} chunk")
            break

        payload = data[offset + 8 : offset + 8 + length]
        stored_crc = struct.unpack(">I", data[offset + 8 + length : chunk_end])[0]
        calculated_crc = zlib.crc32(chunk_type_bytes)
        calculated_crc = zlib.crc32(payload, calculated_crc) & 0xFFFFFFFF
        if stored_crc != calculated_crc:
            errors.append(f"CRC mismatch in {chunk_type} chunk")

        chunks.append(chunk_type)
        if not saw_ihdr:
            if chunk_type != "IHDR":
                errors.append("IHDR is not the first PNG chunk")
            saw_ihdr = True
        if chunk_type == "IEND":
            saw_iend = True
            if chunk_end != len(data):
                errors.append("trailing data exists after IEND")
            break
        offset = chunk_end

    if not saw_ihdr:
        errors.append("missing IHDR chunk")
    if not saw_iend:
        errors.append("missing IEND chunk")
    return chunks, errors


def pixel_hash(image: Image.Image) -> str:
    rendered = image.convert("RGBA")
    digest = hashlib.sha256()
    digest.update(struct.pack(">II", rendered.width, rendered.height))
    digest.update(rendered.tobytes())
    return digest.hexdigest()


def audit_image(path: Path, root: Path) -> ImageResult:
    relative = path.relative_to(root).as_posix()
    chunks, errors = parse_png(path)
    width: int | None = None
    height: int | None = None
    mode: str | None = None
    digest: str | None = None
    info_keys: list[str] = []

    try:
        with Image.open(path) as image:
            image.load()
            width, height = image.size
            mode = image.mode
            digest = pixel_hash(image)
            info_keys = sorted(str(key) for key in image.info)
            if width < 1 or height < 1:
                errors.append("image has invalid dimensions")
    except (OSError, UnidentifiedImageError) as exc:
        errors.append(f"Pillow could not decode image: {exc}")

    sensitive = sorted({chunk for chunk in chunks if chunk in SENSITIVE_PNG_CHUNKS})
    return ImageResult(
        path=relative,
        size_bytes=path.stat().st_size,
        width=width,
        height=height,
        mode=mode,
        pixel_sha256=digest,
        chunks=chunks,
        sensitive_chunks=sensitive,
        pillow_info_keys=info_keys,
        errors=errors,
    )


def sanitize_image(result: ImageResult, root: Path, output_root: Path) -> None:
    source = root / result.path
    destination = output_root / result.path
    destination.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(source) as image:
        image.load()
        has_alpha = "A" in image.getbands() or "transparency" in image.info
        clean = image.convert("RGBA" if has_alpha else "RGB")
        clean.save(destination, format="PNG", optimize=True)

    with Image.open(destination) as sanitized:
        sanitized.load()
        sanitized_hash = pixel_hash(sanitized)

    clean_chunks, clean_errors = parse_png(destination)
    clean_sensitive = sorted({chunk for chunk in clean_chunks if chunk in SENSITIVE_PNG_CHUNKS})
    if clean_errors:
        result.errors.extend(f"sanitized copy: {error}" for error in clean_errors)
    if clean_sensitive:
        result.errors.append(
            "sanitized copy still contains sensitive chunks: " + ", ".join(clean_sensitive)
        )

    result.sanitized_path = destination.relative_to(output_root).as_posix()
    result.sanitized_pixel_sha256 = sanitized_hash
    result.pixels_match = sanitized_hash == result.pixel_sha256
    if not result.pixels_match:
        result.errors.append("sanitized copy does not preserve rendered pixels")


def make_contact_sheet(results: list[ImageResult], source_root: Path, output: Path) -> None:
    if not results:
        return
    columns = 2
    cell_width = 760
    preview_height = 430
    label_height = 72
    rows = math.ceil(len(results) / columns)
    sheet = Image.new("RGB", (columns * cell_width, rows * (preview_height + label_height)), "white")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()

    for index, result in enumerate(results):
        image_path = source_root / result.path
        with Image.open(image_path) as image:
            preview = image.convert("RGB")
            preview.thumbnail((cell_width - 24, preview_height - 24))
        column = index % columns
        row = index // columns
        x = column * cell_width + (cell_width - preview.width) // 2
        y = row * (preview_height + label_height) + (preview_height - preview.height) // 2
        sheet.paste(preview, (x, y))
        label = f"{result.path}\n{result.width}x{result.height} | {result.size_bytes:,} bytes"
        draw.multiline_text(
            (column * cell_width + 12, row * (preview_height + label_height) + preview_height + 6),
            label,
            fill="black",
            font=font,
            spacing=3,
        )

    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, format="PNG", optimize=True)


def write_text_report(
    output: Path,
    root: Path,
    tracked: list[Path],
    results: list[ImageResult],
) -> None:
    lines = [
        "Repository image audit",
        "======================",
        f"Tracked files: {len(tracked)}",
        f"Tracked PNG images: {len(results)}",
        "",
        "Tracked file inventory:",
    ]
    lines.extend(f"- {path.relative_to(root).as_posix()}" for path in tracked)
    lines.append("")
    lines.append("Image findings:")
    for result in results:
        lines.extend(
            [
                f"- {result.path}",
                f"  dimensions: {result.width}x{result.height}",
                f"  mode: {result.mode}",
                f"  size_bytes: {result.size_bytes}",
                f"  chunks: {', '.join(result.chunks)}",
                f"  pillow_info_keys: {', '.join(result.pillow_info_keys) or '(none)'}",
                f"  sensitive_chunks: {', '.join(result.sensitive_chunks) or '(none)'}",
                f"  pixel_sha256: {result.pixel_sha256}",
                f"  sanitized_pixel_sha256: {result.sanitized_pixel_sha256 or '(not generated)'}",
                f"  pixels_match: {result.pixels_match}",
                f"  errors: {'; '.join(result.errors) or '(none)'}",
            ]
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--check", action="store_true", help="Fail on corrupt images or sensitive metadata")
    parser.add_argument("--sanitize-output", type=Path)
    parser.add_argument("--report-file", type=Path)
    parser.add_argument("--json-report", type=Path)
    parser.add_argument("--contact-sheet", type=Path)
    args = parser.parse_args()

    root = args.root.resolve()
    tracked = sorted(git_tracked_files(root))
    image_paths = [path for path in tracked if path.suffix.lower() in IMAGE_SUFFIXES]
    results = [audit_image(path, root) for path in image_paths]

    if args.sanitize_output:
        output_root = args.sanitize_output.resolve()
        for result in results:
            sanitize_image(result, root, output_root)
        if args.contact_sheet:
            make_contact_sheet(results, output_root, args.contact_sheet.resolve())
    elif args.contact_sheet:
        make_contact_sheet(results, root, args.contact_sheet.resolve())

    if args.report_file:
        write_text_report(args.report_file.resolve(), root, tracked, results)
    if args.json_report:
        args.json_report.resolve().parent.mkdir(parents=True, exist_ok=True)
        args.json_report.resolve().write_text(
            json.dumps([asdict(result) for result in results], indent=2) + "\n",
            encoding="utf-8",
        )

    failures: list[str] = []
    for result in results:
        if result.errors:
            failures.extend(f"{result.path}: {error}" for error in result.errors)
        if args.check and result.sensitive_chunks:
            failures.append(
                f"{result.path}: sensitive PNG metadata chunks present: "
                + ", ".join(result.sensitive_chunks)
            )

    if args.check and not results:
        failures.append("no tracked PNG images were found")

    if failures:
        print("Image audit failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"Image audit completed for {len(results)} tracked PNG images.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
