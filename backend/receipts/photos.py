"""Receipt photos on disk: content validation, hashing and storage.

Only JPEG and PNG are accepted (clients convert HEIC and straighten the receipt on the device).
The type comes from the bytes, never from a client filename or header: the JPEG / PNG structure
is walked (markers or chunks, PNG CRCs, a complete file) and the pixel size is read from it. The
storage path is built from the receipt UUID only: `<first two chars>/<uuid>.<jpg|png>` below the
photos directory, so nothing a client sends can name a path.

Nothing in here deletes a photo by age; `delete_photo` is called only by the archive confirmation
(receipts/archive.py) once the laptop's copy was verified.
"""

from __future__ import annotations

import hashlib
import os
import struct
import uuid
import zlib
from dataclasses import dataclass
from pathlib import Path

JPEG = "image/jpeg"
PNG = "image/png"
EXTENSIONS = {JPEG: "jpg", PNG: "png"}
MAX_SIDE_PX = 20000
MAX_PIXELS = 150_000_000


class InvalidImage(ValueError):
    """The bytes are not a complete, plausible JPEG / PNG."""


@dataclass(frozen=True)
class ImageInfo:
    media_type: str
    width: int
    height: int

    @property
    def extension(self) -> str:
        return EXTENSIONS[self.media_type]


def _check_size(width: int, height: int) -> None:
    if width < 1 or height < 1:
        raise InvalidImage("the image has no pixels")
    if width > MAX_SIDE_PX or height > MAX_SIDE_PX or width * height > MAX_PIXELS:
        raise InvalidImage(f"the image is too large ({width}x{height} px)")


def _jpeg_info(data: bytes) -> ImageInfo:
    n = len(data)
    if n < 4 or data[:2] != b"\xff\xd8":
        raise InvalidImage("not a JPEG")
    if data.rstrip(b"\x00")[-2:] != b"\xff\xd9":
        raise InvalidImage("the JPEG is incomplete (no end marker)")
    pos = 2
    size: tuple[int, int] | None = None
    while pos < n:
        if data[pos] != 0xFF:
            raise InvalidImage("corrupt JPEG segment structure")
        while pos < n and data[pos] == 0xFF:  # fill bytes
            pos += 1
        if pos >= n:
            break
        marker = data[pos]
        pos += 1
        if marker in (0x01, 0xD8) or 0xD0 <= marker <= 0xD7:
            continue  # standalone markers
        if marker == 0xD9:
            break
        if pos + 2 > n:
            raise InvalidImage("truncated JPEG")
        (seglen,) = struct.unpack(">H", data[pos : pos + 2])
        if seglen < 2 or pos + seglen > n:
            raise InvalidImage("truncated JPEG segment")
        sof = 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC)
        if sof:
            if seglen < 8:
                raise InvalidImage("corrupt JPEG frame header")
            height, width = struct.unpack(">HH", data[pos + 3 : pos + 7])
            size = (width, height)
        if marker == 0xDA:  # start of scan: entropy-coded data follows, headers are done
            break
        pos += seglen
    if size is None:
        raise InvalidImage("the JPEG has no frame header")
    _check_size(*size)
    return ImageInfo(JPEG, *size)


def _png_info(data: bytes) -> ImageInfo:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise InvalidImage("not a PNG")
    pos, n = 8, len(data)
    size: tuple[int, int] | None = None
    first = True
    seen_iend = False
    while pos + 12 <= n:
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        ctype = data[pos + 4 : pos + 8]
        end = pos + 8 + length
        if end + 4 > n:
            raise InvalidImage("truncated PNG chunk")
        (crc,) = struct.unpack(">I", data[end : end + 4])
        if zlib.crc32(data[pos + 4 : end]) & 0xFFFFFFFF != crc:
            raise InvalidImage("corrupt PNG (bad chunk checksum)")
        if first:
            if ctype != b"IHDR" or length != 13:
                raise InvalidImage("PNG does not start with a header chunk")
            width, height = struct.unpack(">II", data[pos + 8 : pos + 16])
            size = (width, height)
            first = False
        if ctype == b"IEND":
            seen_iend = True
            pos = end + 4
            break
        pos = end + 4
    if size is None or not seen_iend:
        raise InvalidImage("the PNG is incomplete (no end chunk)")
    if data[pos:].strip(b"\x00"):
        raise InvalidImage("data after the end of the PNG")
    _check_size(*size)
    return ImageInfo(PNG, *size)


def inspect_image(data: bytes) -> ImageInfo:
    """Validate `data` as JPEG or PNG from its content. Raises InvalidImage."""
    if data[:2] == b"\xff\xd8":
        return _jpeg_info(data)
    if data[:4] == b"\x89PNG":
        return _png_info(data)
    raise InvalidImage("only JPEG and PNG images are accepted")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_uuid(value: str) -> str:
    """Canonical lowercase UUID text; ValueError if `value` is not one."""
    return str(uuid.UUID(value))


def photo_relpath(receipt_id: str, media_type: str) -> str:
    """`ab/ab12....jpg`: derived from the (validated) receipt UUID and the sniffed type only."""
    rid = canonical_uuid(receipt_id)
    return f"{rid[:2]}/{rid}.{EXTENSIONS[media_type]}"


def photo_abspath(photos_dir: Path, relpath: str) -> Path:
    """Absolute path of a stored photo; refuses anything that resolves outside `photos_dir`."""
    root = photos_dir.resolve()
    path = (root / relpath).resolve()
    if root not in path.parents:
        raise ValueError("photo path escapes the photos directory")
    return path


def write_photo(photos_dir: Path, relpath: str, data: bytes) -> Path:
    """Atomic write (temp file in the same directory, fsync, rename)."""
    path = photo_abspath(photos_dir, relpath)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)
    return path


def read_photo(photos_dir: Path, relpath: str) -> bytes:
    return photo_abspath(photos_dir, relpath).read_bytes()


def delete_photo(photos_dir: Path, relpath: str) -> bool:
    """Remove a stored photo; True if a file was deleted (called by the archive confirmation)."""
    path = photo_abspath(photos_dir, relpath)
    try:
        path.unlink()
    except FileNotFoundError:
        return False
    return True
