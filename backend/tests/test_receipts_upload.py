"""Photo upload: idempotency (client UUID), content validation, size limit, storage paths."""

from __future__ import annotations

import hashlib
import os
import uuid

import pytest

from receipts import photos
from receipts.db.models import ExtractionJob, Receipt
from tests.receipts_helpers import BASE, make_jpeg, make_png

RID = "3b241101-e2bb-4255-8caf-4136c566a962"


def put(client, rid, data, ctype="image/jpeg", **kw):
    return client.put(f"{BASE}/{rid}/photo", content=data, headers={"Content-Type": ctype}, **kw)


def test_upload_creates_receipt_stores_file_and_queues_extraction(rclient, rdb, photos_dir):
    data = make_jpeg(1)
    r = put(rclient, RID, data)
    assert r.status_code == 201
    body = r.json()
    rec = body["receipt"]
    assert body["created"] is True
    assert rec["id"] == RID
    assert rec["photo_sha256"] == hashlib.sha256(data).hexdigest()
    assert rec["photo_location"] == "server" and rec["photo_bytes"] == len(data)
    assert rec["extraction_status"] == "queued"
    stored = photos_dir / RID[:2] / f"{RID}.jpg"
    assert stored.read_bytes() == data
    job = rdb.query(ExtractionJob).one()
    assert (job.receipt_id, job.status, job.attempts) == (RID, "queued", 0)


def test_same_upload_twice_is_idempotent(rclient, rdb, photos_dir):
    data = make_jpeg(2)
    first = put(rclient, RID, data)
    second = put(rclient, RID, data)
    third = put(rclient, RID.upper(), data)  # the same UUID spelled differently
    assert (first.status_code, second.status_code, third.status_code) == (201, 200, 200)
    assert second.json()["created"] is False
    assert second.json()["receipt"] == first.json()["receipt"]
    assert rdb.query(Receipt).count() == 1
    assert rdb.query(ExtractionJob).count() == 1
    assert len(list(photos_dir.rglob("*.jpg"))) == 1


def test_retry_after_the_file_was_lost_heals_it(rclient, photos_dir):
    data = make_jpeg(3)
    put(rclient, RID, data)
    (photos_dir / RID[:2] / f"{RID}.jpg").unlink()
    assert put(rclient, RID, data).status_code == 200
    assert (photos_dir / RID[:2] / f"{RID}.jpg").read_bytes() == data


def test_other_bytes_under_the_same_id_conflict_and_change_nothing(rclient, photos_dir):
    first = make_jpeg(4)
    put(rclient, RID, first)
    r = put(rclient, RID, make_jpeg(5))
    assert r.status_code == 409 and r.json()["detail"]["code"] == "photo_conflict"
    assert (photos_dir / RID[:2] / f"{RID}.jpg").read_bytes() == first


def test_same_photo_under_another_id_is_a_duplicate(rclient, rdb):
    data = make_jpeg(6)
    put(rclient, RID, data)
    other = str(uuid.uuid4())
    r = put(rclient, other, data)
    assert r.status_code == 409
    assert r.json()["detail"] == {
        "code": "duplicate_image",
        "message": "This exact photo belongs to another receipt.",
        "duplicate_of": RID,
    }
    assert rdb.get(Receipt, other) is None


def test_png_is_accepted(rclient, photos_dir):
    r = put(rclient, RID, make_png(1), ctype="image/png")
    assert r.status_code == 201
    assert r.json()["receipt"]["photo_media_type"] == "image/png"
    assert (photos_dir / RID[:2] / f"{RID}.png").exists()


@pytest.mark.parametrize(
    ("data", "ctype", "code"),
    [
        (b"", "image/jpeg", "empty_body"),
        (b"GIF89a" + bytes(100), "image/gif", "invalid_image"),
        (b"%PDF-1.7 not an image", "application/pdf", "invalid_image"),
        (b"<html>hi</html>", "image/jpeg", "invalid_image"),  # claims jpeg, is not
        (make_jpeg(7)[:-30], "image/jpeg", "invalid_image"),  # truncated JPEG
        (make_png(2)[:-12], "image/png", "invalid_image"),  # PNG without IEND
        (make_jpeg(8), "image/png", "content_type_mismatch"),  # JPEG sent as PNG
    ],
)
def test_content_is_validated_not_the_header(rclient, rdb, photos_dir, data, ctype, code):
    r = put(rclient, RID, data, ctype=ctype)
    assert r.status_code in (400, 415), r.text
    assert r.json()["detail"]["code"] == code
    assert rdb.query(Receipt).count() == 0
    assert not list(photos_dir.rglob("*.*")) if photos_dir.exists() else True


def test_jpeg_content_with_a_neutral_content_type_is_accepted(rclient):
    r = put(rclient, RID, make_jpeg(9), ctype="application/octet-stream")
    assert r.status_code == 201


def test_corrupt_png_checksum_is_rejected():
    data = bytearray(make_png(3))
    data[20] ^= 0xFF  # inside IHDR: CRC no longer matches
    with pytest.raises(photos.InvalidImage):
        photos.inspect_image(bytes(data))


def test_implausible_dimensions_are_rejected(rclient):
    r = put(rclient, RID, make_jpeg(10, width=30000, height=10))
    assert r.status_code == 415
    assert "too large" in r.json()["detail"]["message"]


def test_size_limit(rclient, monkeypatch, rdb):
    from receipts.settings import get_settings

    monkeypatch.setenv("RECEIPTS_MAX_PHOTO_BYTES", "300")
    get_settings.cache_clear()
    assert put(rclient, RID, make_jpeg(11)).status_code == 201  # ~200 bytes
    big = make_jpeg(12) + b"\x00" * 400  # trailing NULs keep it a valid JPEG, but too big
    r = put(rclient, str(uuid.uuid4()), big)
    assert r.status_code == 413 and r.json()["detail"]["code"] == "too_large"


def test_sha256_header_catches_a_damaged_upload(rclient, rdb):
    data = make_jpeg(13)
    r = rclient.put(
        f"{BASE}/{RID}/photo",
        content=data,
        headers={"Content-Type": "image/jpeg", "X-Content-SHA256": "0" * 64},
    )
    assert r.status_code == 422 and r.json()["detail"]["code"] == "sha256_mismatch"
    good = rclient.put(
        f"{BASE}/{RID}/photo",
        content=data,
        headers={
            "Content-Type": "image/jpeg",
            "X-Content-SHA256": hashlib.sha256(data).hexdigest(),
        },
    )
    assert good.status_code == 201


@pytest.mark.parametrize("bad_id", ["not-a-uuid", "..%2f..%2fetc%2fpasswd", "12345", "a" * 40])
def test_the_path_comes_from_the_uuid_only(rclient, photos_dir, bad_id):
    r = put(rclient, bad_id, make_jpeg(14))
    assert r.status_code in (404, 422)
    assert not photos_dir.exists() or not list(photos_dir.rglob("*.*"))


def test_stored_path_is_uuid_derived_and_stays_inside_the_photos_dir(photos_dir):
    rel = photos.photo_relpath(RID, photos.JPEG)
    assert rel == f"{RID[:2]}/{RID}.jpg"
    with pytest.raises(ValueError):
        photos.photo_abspath(photos_dir, "../outside.jpg")
    with pytest.raises(ValueError):
        photos.photo_relpath("../../x", photos.JPEG)


def test_download_needs_a_photo_on_the_server(rclient):
    data = make_jpeg(15)
    put(rclient, RID, data)
    r = rclient.get(f"{BASE}/{RID}/photo")
    assert r.status_code == 200 and r.content == data
    assert r.headers["content-type"] == "image/jpeg"
    assert r.headers["x-content-sha256"] == hashlib.sha256(data).hexdigest()
    assert r.headers["cache-control"] == "private, no-store"
    assert rclient.get(f"{BASE}/{uuid.uuid4()}/photo").status_code == 404
    assert os.environ.get("RECEIPTS_PHOTOS_DIR")
