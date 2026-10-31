"""Photo retention: the laptop's sha256 confirmation is the only thing that deletes a photo;
status fields, reminders and the scheduled job."""

from __future__ import annotations

import hashlib
import os
import time
from datetime import timedelta

import httpx
import respx
from apscheduler.schedulers.background import BackgroundScheduler
from sqlalchemy import select

from core.db import utcnow
from receipts import archive, jobs, notify, state, worker
from receipts.db.models import Receipt
from receipts.llm.base import LLMError
from receipts.settings import get_settings
from tests.receipts_helpers import BASE, FakeProvider, make_jpeg, receipt_json

RID = "3b241101-e2bb-4255-8caf-4136c566a962"
R2 = "7a1f2a3e-1111-4222-8333-444455556666"
DEVICE = "macbook-archive"


def sha(seed: int) -> str:
    return hashlib.sha256(make_jpeg(seed)).hexdigest()


def stored(photos_dir, rid=RID):
    return photos_dir / rid[:2] / f"{rid}.jpg"


def upload(client, rid=RID, seed=1):
    r = client.put(
        f"{BASE}/{rid}/photo", content=make_jpeg(seed), headers={"Content-Type": "image/jpeg"}
    )
    assert r.status_code in (200, 201), r.text


def extracted(client, factory, rid=RID, seed=1):
    upload(client, rid, seed)
    worker.run_next(factory, FakeProvider())


def confirm(client, rid=RID, sha256=None, seed=1, **kw):
    return client.post(
        f"{BASE}/{rid}/archive-confirm",
        json={"sha256": sha256 or sha(seed), "device_id": DEVICE, **kw},
    )


def receipt(db, rid=RID) -> Receipt:
    db.expire_all()
    return db.get(Receipt, rid)


# --------------------------------------------------------------------------- list + download


def test_pending_list_and_download(rclient, rfactory):
    upload(rclient)
    pending = rclient.get(f"{BASE}/archive/pending").json()
    assert pending["count"] == 1
    p = pending["photos"][0]
    assert (p["id"], p["sha256"], p["bytes"], p["media_type"]) == (
        RID,
        sha(1),
        len(make_jpeg(1)),
        "image/jpeg",
    )
    assert (p["archivable"], p["blocked_reason"]) == (False, "extraction_pending")
    assert p["download"] == f"/api/v1/receipts/{RID}/photo"
    worker.run_next(rfactory, FakeProvider())
    p = rclient.get(f"{BASE}/archive/pending").json()["photos"][0]
    assert (p["archivable"], p["blocked_reason"]) == (True, None)
    assert rclient.get(p["download"]).content == make_jpeg(1)


# --------------------------------------------------------------------------- confirm


def test_matching_sha_archives_and_deletes_the_file(rclient, rfactory, rdb, photos_dir):
    extracted(rclient, rfactory)
    assert stored(photos_dir).exists()
    r = confirm(rclient)
    assert r.status_code == 200 and r.json() == {"status": "archived", "receipt_id": RID}
    rec = receipt(rdb)
    assert rec.photo_location == "archived" and rec.archived_at is not None
    assert rec.archived_by == DEVICE and rec.photo_path is None
    assert not stored(photos_dir).exists()
    # sync still carries the receipt, and says where the photo is now
    synced = rclient.get(f"{BASE}/sync/pull").json()["receipts"][0]
    assert synced["photo_location"] == "archived" and synced["archived_at"] is not None
    assert synced["store"] == "Edeka" and synced["photo_sha256"] == sha(1)
    assert rclient.get(f"{BASE}/archive/pending").json()["count"] == 0
    gone = rclient.get(f"{BASE}/{RID}/photo")
    assert gone.status_code == 410 and gone.json()["detail"]["code"] == "photo_archived"


def test_sha_mismatch_is_an_error_and_keeps_the_file(rclient, rfactory, rdb, photos_dir):
    extracted(rclient, rfactory)
    r = confirm(rclient, sha256=sha(99))
    assert r.status_code == 409 and r.json()["detail"]["code"] == "sha256_mismatch"
    assert stored(photos_dir).read_bytes() == make_jpeg(1)
    rec = receipt(rdb)
    assert rec.photo_location == "server" and rec.archived_at is None
    assert state.get_value(rdb, state.LAST_ARCHIVE_SYNC) is None  # a failed confirm is no sync


def test_confirming_twice_is_a_harmless_noop(rclient, rfactory, rdb, photos_dir):
    extracted(rclient, rfactory)
    assert confirm(rclient).json()["status"] == "archived"
    first_time = receipt(rdb).archived_at
    again = confirm(rclient)
    assert again.status_code == 200 and again.json()["status"] == "already_archived"
    assert receipt(rdb).archived_at == first_time
    assert not stored(photos_dir).exists()
    assert confirm(rclient, sha256=sha(99)).status_code == 409  # still checked against the sha


def test_uppercase_sha_is_fine_and_garbage_is_rejected(rclient, rfactory):
    extracted(rclient, rfactory)
    assert confirm(rclient, sha256="abc").status_code == 422
    assert confirm(rclient, sha256=sha(1).upper()).status_code == 200
    assert confirm(rclient, rid=R2).status_code == 404


def test_archive_waits_for_the_extraction(rclient, rfactory, rdb, photos_dir):
    upload(rclient)  # queued, not extracted
    r = confirm(rclient)
    assert r.status_code == 409 and r.json()["detail"]["code"] == "extraction_pending"
    assert stored(photos_dir).exists() and receipt(rdb).photo_location == "server"


def test_failed_extraction_needs_an_explicit_give_up(rclient, rfactory, rdb, photos_dir):
    upload(rclient)
    worker.run_next(rfactory, FakeProvider([LLMError("refusal", "no")]))
    r = confirm(rclient)
    assert r.status_code == 409 and r.json()["detail"]["code"] == "extraction_failed"
    assert stored(photos_dir).exists()
    pending = rclient.get(f"{BASE}/archive/pending").json()["photos"][0]
    assert (pending["archivable"], pending["blocked_reason"]) == (False, "extraction_failed")
    ok = confirm(rclient, accept_failed=True)
    assert ok.status_code == 200 and ok.json()["status"] == "archived"
    assert not stored(photos_dir).exists()
    rec = receipt(rdb)  # the failed receipt is still there for the clients
    assert rec.extraction_status == "failed" and rec.photo_location == "archived"


def test_an_archived_photo_is_not_resurrected_by_a_late_upload_retry(rclient, rfactory, photos_dir):
    extracted(rclient, rfactory)
    confirm(rclient)
    r = rclient.put(
        f"{BASE}/{RID}/photo", content=make_jpeg(1), headers={"Content-Type": "image/jpeg"}
    )
    assert r.status_code == 200 and r.json()["created"] is False
    assert r.json()["receipt"]["photo_location"] == "archived"
    assert not stored(photos_dir).exists()
    assert rclient.post(f"{BASE}/{RID}/extraction/retry").status_code == 409


def test_a_crash_between_commit_and_delete_is_finished_by_the_next_confirm_or_sweep(
    rclient, rfactory, rdb, photos_dir
):
    extracted(rclient, rfactory)
    rec = receipt(rdb)
    rec.photo_location, rec.archived_at = "archived", utcnow()  # committed, file not yet removed
    rdb.commit()
    assert stored(photos_dir).exists()
    assert archive.sweep_archived(rdb, get_settings()) == 1
    assert not stored(photos_dir).exists() and receipt(rdb).photo_path is None


# --------------------------------------------------------------------------- never by age


def test_nothing_deletes_a_photo_by_age(rclient, rfactory, rdb, photos_dir):
    ids = [f"0000000{i}-0000-4000-8000-000000000000" for i in range(3)]
    for i, rid in enumerate(ids):
        upload(rclient, rid, seed=10 + i)
    # ten years old on disk and in the database
    ancient = time.time() - 10 * 365 * 86400
    for rid in ids:
        os.utime(stored(photos_dir, rid), (ancient, ancient))
    for rec in rdb.scalars(select(Receipt)):
        rec.uploaded_at = rec.created_at = utcnow() - timedelta(days=3650)
    rdb.commit()
    stray = photos_dir / "ff" / "ff000000-0000-4000-8000-00000000dead.jpg"
    stray.parent.mkdir(parents=True)
    stray.write_bytes(make_jpeg(77))  # a file no row points at (e.g. after a restored database)

    # run everything the server does on its own: the extraction job, the daily job, the sweep
    while worker.run_next(rfactory, FakeProvider([receipt_json()])):
        pass
    jobs.daily_job()
    archive.sweep_archived(rdb, get_settings())
    archive.check_and_remind(rfactory, get_settings(), lambda title, text: True)

    for rid in ids:
        assert stored(photos_dir, rid).exists(), rid
        assert receipt(rdb, rid).photo_location == "server"
    assert stray.exists()
    assert rclient.get(f"{BASE}/archive/pending").json()["count"] == 3
    # and only the matching confirmation removes one
    assert confirm(rclient, rid=ids[0], seed=10).status_code == 200
    assert not stored(photos_dir, ids[0]).exists()
    assert stored(photos_dir, ids[1]).exists() and stored(photos_dir, ids[2]).exists()


# --------------------------------------------------------------------------- status


def test_status_fields(rclient, rfactory, rdb):
    empty = rclient.get(f"{BASE}/status").json()
    assert (empty["unarchived_count"], empty["unarchived_bytes"]) == (0, 0)
    assert empty["last_archive_sync_at"] is None and empty["archive_overdue"] is False
    assert empty["disk_free_bytes"] > 0 and empty["disk_warning"] is False
    assert empty["archive_reminder_days"] == 30
    upload(rclient)
    st = rclient.get(f"{BASE}/status").json()
    assert (st["unarchived_count"], st["unarchived_bytes"]) == (1, len(make_jpeg(1)))
    assert st["queue"] == {"queued": 1, "processing": 0, "done": 0, "failed": 0}
    assert st["llm"]["provider"] == "none" and st["llm"]["model"] == "claude-haiku-5-5"
    assert "key" not in str(st["llm"]).lower().replace("credential_configured", "")


def test_overdue_needs_pending_photos_and_no_recent_laptop_sync(rclient, rfactory, rdb):
    upload(rclient)
    now = utcnow()
    settings = get_settings()
    assert archive.status(rdb, settings, now)["archive_overdue"] is False
    # never synced: counted from the oldest waiting photo
    assert archive.status(rdb, settings, now + timedelta(days=29))["archive_overdue"] is False
    assert archive.status(rdb, settings, now + timedelta(days=31))["archive_overdue"] is True
    # the laptop syncs: the clock restarts
    r = rclient.post(f"{BASE}/archive/sync", json={"device_id": DEVICE})
    assert r.status_code == 200
    st = rclient.get(f"{BASE}/status").json()
    assert (
        st["archive_device_id"] == DEVICE
        and st["last_archive_sync_at"] == r.json()["last_archive_sync_at"]
    )
    assert archive.status(rdb, settings, now + timedelta(days=29))["archive_overdue"] is False
    assert archive.status(rdb, settings, now + timedelta(days=31))["archive_overdue"] is True
    # nothing pending: never overdue, however old the last sync is
    extracted_and_archived(rclient, rfactory)
    assert archive.status(rdb, settings, now + timedelta(days=400))["archive_overdue"] is False


def extracted_and_archived(client, factory):
    worker.run_next(factory, FakeProvider())
    assert confirm(client).status_code == 200


def test_a_confirm_counts_as_a_laptop_sync(rclient, rfactory, rdb):
    extracted(rclient, rfactory)
    confirm(rclient)
    st = rclient.get(f"{BASE}/status").json()
    assert st["last_archive_sync_at"] is not None and st["archive_device_id"] == DEVICE


def test_disk_warning_threshold_is_configurable(rclient, monkeypatch):
    monkeypatch.setenv("RECEIPTS_DISK_WARNING_FREE_MB", str(10**9))  # petabytes: always short
    get_settings.cache_clear()
    st = rclient.get(f"{BASE}/status").json()
    assert st["disk_warning"] is True and st["disk_warning_free_mb"] == 10**9


# --------------------------------------------------------------------------- reminders


def test_reminder_is_sent_when_overdue_and_at_most_every_few_days(rclient, rfactory, rdb):
    upload(rclient)
    settings = get_settings()
    sent: list[tuple[str, str]] = []

    def notifier(title, text):
        sent.append((title, text))
        return True

    now = utcnow()
    assert archive.check_and_remind(rfactory, settings, notifier, now) == "none"
    late = now + timedelta(days=31)
    assert archive.check_and_remind(rfactory, settings, notifier, late) == "sent"
    assert "1 receipt photo(s)" in sent[0][1] and "30 days" in sent[0][1]
    assert (
        archive.check_and_remind(rfactory, settings, notifier, late + timedelta(days=2))
        == "throttled"
    )
    assert (
        archive.check_and_remind(rfactory, settings, notifier, late + timedelta(days=3.1)) == "sent"
    )
    assert len(sent) == 2


def test_undelivered_reminder_is_retried_the_next_day(rclient, rfactory):
    upload(rclient)
    settings = get_settings()
    late = utcnow() + timedelta(days=40)
    assert archive.check_and_remind(rfactory, settings, lambda *_: False, late) == "undelivered"
    assert (
        archive.check_and_remind(rfactory, settings, lambda *_: True, late + timedelta(days=1))
        == "sent"
    )


def test_disk_warning_also_triggers_a_reminder(rclient, rfactory, monkeypatch):
    monkeypatch.setenv("RECEIPTS_DISK_WARNING_FREE_MB", str(10**9))
    get_settings.cache_clear()
    texts: list[str] = []
    assert (
        archive.check_and_remind(rfactory, get_settings(), lambda t, m: texts.append(m) or True)
        == "sent"
    )
    assert "GB free" in texts[0]


@respx.mock
def test_notifier_posts_to_the_configured_url(monkeypatch):
    assert notify.send("t", "m") is False  # no channel configured: not delivered
    monkeypatch.setenv("RECEIPTS_NOTIFY_URL", "https://ntfy.example/receipts-alerts")
    get_settings.cache_clear()
    route = respx.post("https://ntfy.example/receipts-alerts").mock(return_value=httpx.Response(200))
    assert notify.send("Receipts: action needed", "archive them") is True
    req = route.calls[0].request
    assert req.content == b"archive them" and req.headers["Title"] == "Receipts: action needed"
    respx.post("https://ntfy.example/receipts-alerts").mock(return_value=httpx.Response(500))
    assert notify.send("t", "m") is False


def test_daily_job_is_registered_through_the_core_scheduler(monkeypatch):
    monkeypatch.setenv("RECEIPTS_REMINDER_TIME", "08:15")
    get_settings.cache_clear()
    sched = BackgroundScheduler(timezone="Europe/Vienna")
    jobs.add_receipts_jobs(sched, get_settings())
    job = sched.get_job("receipts_daily")
    assert job is not None and "hour='8'" in str(job.trigger) and "minute='15'" in str(job.trigger)


def test_daily_job_never_raises(monkeypatch):
    monkeypatch.setattr(archive, "sweep_archived", lambda *a, **k: 1 / 0)
    jobs.daily_job()  # logged, not raised
