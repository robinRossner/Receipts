"""Extraction pipeline and queue (fake LLM): results, validation texts, failure handling, bounded
retries, restart recovery, the retry endpoint and user edits surviving retries."""

from __future__ import annotations

import pytest
from sqlalchemy import select

from core.db import utcnow
from receipts import worker
from receipts.db.models import ExtractionJob, ItemDictionary, LineItem, Receipt
from receipts.extraction.validate import parse_response, validate_receipt
from receipts.llm.base import LLMError
from receipts.settings import get_settings
from tests.receipts_helpers import (
    BASE,
    FakeProvider,
    make_jpeg,
    path_number,
    receipt_json,
    transient_error,
)

RID = "3b241101-e2bb-4255-8caf-4136c566a962"
FUTURE = "2099-01-01T00:00:00Z"


def upload(client, rid=RID, seed=1):
    r = client.put(
        f"{BASE}/{rid}/photo", content=make_jpeg(seed), headers={"Content-Type": "image/jpeg"}
    )
    assert r.status_code == 201, r.text
    return r.json()["receipt"]


def pull(client):
    return client.get(f"{BASE}/sync/pull").json()


def reload(db, rid=RID) -> Receipt:
    db.expire_all()
    return db.get(Receipt, rid)


@pytest.fixture(autouse=True)
def _fast_backoff(monkeypatch):
    monkeypatch.setenv("RECEIPTS_EXTRACTION_BACKOFF_S", "0")
    get_settings.cache_clear()


# --------------------------------------------------------------------------- happy path


def test_extraction_fills_the_receipt_items_and_dictionary(rclient, rdb, rfactory):
    upload(rclient)
    provider = FakeProvider([receipt_json(store="rewe", date="2026-03-01")])
    assert worker.run_next(rfactory, provider) is True
    assert worker.run_next(rfactory, provider) is False  # queue drained

    r = reload(rdb)
    assert (r.store, r.date, r.time, r.total, r.computed_sum) == (
        "Rewe",
        "2026-03-01",
        "09:12",
        2.74,
        2.74,
    )
    assert r.needs_review is False and r.review_reasons == [] and r.reviewed_at is None
    assert (r.extraction_status, r.extraction_attempts, r.extraction_error) == ("done", 1, None)
    assert r.extraction_provider == "fake/test-model" and r.extraction_result["total"] == 2.74
    items = rdb.scalars(select(LineItem).order_by(LineItem.position)).all()
    assert [(i.name_de, i.quantity, i.unit_price, i.total_price) for i in items] == [
        ("Bio Eier 10er", 1.0, 2.49, 2.49),
        ("Pfand", 1.0, 0.25, 0.25),
    ]
    d = rdb.get(ItemDictionary, items[0].item_dictionary_id)
    assert (d.category, d.subcategory, d.item_group) == ("Food", "Pantry", "Legumes")
    assert d.canonical_name == "bio eier 10er" and d.is_manual_override is False
    # the vision call got the photo bytes and the Mac app's prompt
    call = provider.extract_calls[0]
    assert call["image"] == make_jpeg(1) and call["media_type"] == "image/jpeg"
    assert call["prompt"].startswith("You are an expert OCR and data extraction AI.")


def test_results_reach_clients_through_pull(rclient, rfactory):
    upload(rclient)
    first = pull(rclient)
    assert first["receipts"][0]["extraction_status"] == "queued"
    worker.run_next(rfactory, FakeProvider())
    after = rclient.get(f"{BASE}/sync/pull", params={"since": first["cursor"]}).json()
    rec = after["receipts"][0]
    assert rec["store"] == "Edeka" and rec["extraction_status"] == "done"
    assert len(after["line_items"]) == 2 and len(after["dictionary"]) == 2
    assert {i["receipt_id"] for i in after["line_items"]} == {RID}


def test_keyword_rules_decide_without_the_llm(rclient, rfactory, rdb):
    upload(rclient)
    provider = FakeProvider([receipt_json([("Walnüsse", 1, 2.99)])])
    worker.run_next(rfactory, provider)
    assert provider.classify_calls == []  # "walnuss" rule: no classification call
    d = rdb.scalar(select(ItemDictionary))
    assert d.item_group == "Nuts, Seeds & Dried Fruit"


def test_a_printed_branch_name_is_stored_as_the_chain(rclient, rdb, rfactory):
    upload(rclient)
    provider = FakeProvider([receipt_json(store="EDEKA Musterstadt", date="2026-03-01")])
    assert worker.run_next(rfactory, provider) is True
    assert reload(rdb).store == "Edeka"


def test_repeated_names_share_one_dictionary_entry(rclient, rfactory, rdb):
    upload(rclient)
    provider = FakeProvider(
        [receipt_json([("Pfand", 1, 0.25), ("Pfand", 1, 0.25), ("Pfand", 1, 0.25)])]
    )
    worker.run_next(rfactory, provider)
    assert rdb.query(ItemDictionary).count() == 1
    assert rdb.scalar(select(ItemDictionary)).times_seen == 3
    assert rdb.query(LineItem).count() == 3
    assert len(provider.classify_calls) == 1  # one batched call for the whole receipt


def test_a_users_dictionary_correction_is_not_touched_by_extraction(rclient, rfactory, rdb):
    upload(rclient)
    worker.run_next(rfactory, FakeProvider([receipt_json([("Bio Eier 10er", 1, 2.49)])]))
    entry = rdb.scalar(select(ItemDictionary))
    push = rclient.post(
        f"{BASE}/sync/push",
        json={
            "device_id": "phone",
            "dictionary": [
                {
                    "id": entry.id,
                    "canonical_name": entry.canonical_name,
                    "category": "Food",
                    "subcategory": "Dairy & Eggs",
                    "item_group": "Eggs",
                    "is_manual_override": True,
                    "updated_at": FUTURE,
                }
            ],
        },
    )
    assert push.json()["results"][0]["status"] == "applied"
    other = "7a1f2a3e-1111-4222-8333-444455556666"
    upload(rclient, other, seed=2)
    worker.run_next(rfactory, FakeProvider([receipt_json([("Bio Eier 10er", 1, 2.49)])]))
    rdb.expire_all()
    entry = rdb.scalar(select(ItemDictionary))
    assert (entry.item_group, entry.is_manual_override) == ("Eggs", True)
    assert entry.times_seen == 2  # seen again, category untouched


def test_possible_duplicate_is_flagged_not_dropped(rclient, rfactory, rdb):
    upload(rclient)
    provider = FakeProvider([receipt_json()])
    worker.run_next(rfactory, provider)
    other = "7a1f2a3e-1111-4222-8333-444455556666"
    upload(rclient, other, seed=2)
    worker.run_next(rfactory, provider)
    second = reload(rdb, other)
    assert second.needs_review is True
    assert second.review_reasons == [f"Possible duplicate of receipt {RID}"]
    assert rdb.query(LineItem).filter_by(receipt_id=other).count() == 2


# --------------------------------------------------------------------------- validation port


def test_validation_texts_match_the_mac_app():
    raw = parse_response(
        receipt_json([("Pfand", 1, 0.27), ("Pfand", 1, 0.9), ("Käse", 2, 1.0)], total=9.0)
    )
    # line math error on the third item is injected through a bad total_price
    raw.items[2].total_price = 5.0
    out = validate_receipt(raw)
    assert out.needs_review is True
    assert out.review_reasons == [
        "Pfand item 'Pfand' had unit_price 0.27 - corrected to 0.25.",
        "Pfand item 'Pfand' has unit_price 0.9, which isn't close to any standard German "
        "deposit amount - check manually.",
        "Item prices sum to 6.15, but printed total is 9.0 (difference: 2.85). "
        "Check raw_text per item.",
        "Item #2 (Käse): 2.0 x 1.0 = 2.0, but total_price is 5.0",
    ]
    assert out.items[0].unit_price == 0.25 and out.items[0].price_normalized is True


def test_missing_total_and_coercions():
    out = validate_receipt(
        parse_response(
            'prose {"store": "X", "items": [{"name": "A", "quantity": "1,5", '
            '"unit_price": "2,00", "total_price": 3.0}, {"name": "no price"}]} trailing'
        )
    )
    assert [i.name for i in out.items] == ["A"]  # the line without a price is dropped
    assert out.items[0].quantity == 1.5 and out.items[0].unit_price == 2.0
    assert out.review_reasons == ["No total found on receipt"]


# --------------------------------------------------------------------------- failure and retries


def test_invalid_json_is_retried_once_within_the_job(rclient, rfactory, rdb):
    upload(rclient)
    provider = FakeProvider(["I cannot read this", receipt_json()])
    worker.run_next(rfactory, provider)
    assert len(provider.extract_calls) == 2
    assert reload(rdb).extraction_status == "done"


def test_failed_extraction_leaves_photo_and_receipt_visible(rclient, rfactory, rdb, photos_dir):
    upload(rclient)
    provider = FakeProvider([LLMError("refusal", "Claude declined to answer")])
    worker.run_next(rfactory, provider)
    r = reload(rdb)
    assert (
        r.extraction_status == "failed" and r.extraction_attempts == 1
    )  # not retryable: no retries
    assert "declined" in r.extraction_error
    assert r.photo_location == "server" and (photos_dir / RID[:2] / f"{RID}.jpg").exists()
    assert r.deleted_at is None and rdb.query(LineItem).count() == 0
    rec = pull(rclient)["receipts"][0]  # clients see the failure
    assert (rec["id"], rec["extraction_status"], rec["photo_location"]) == (RID, "failed", "server")
    assert "declined" in rec["extraction_error"]


def test_transient_errors_are_retried_a_bounded_number_of_times(rclient, rfactory, rdb):
    upload(rclient)
    provider = FakeProvider([transient_error("overloaded")])
    runs = 0
    while worker.run_next(rfactory, provider):
        runs += 1
        assert runs < 10
    r = reload(rdb)
    assert runs == get_settings().receipts_extraction_max_attempts == 3
    assert (r.extraction_status, r.extraction_attempts) == ("failed", 3)
    assert r.extraction_error == "overloaded"
    assert len(provider.extract_calls) == 3


def test_a_later_attempt_can_succeed(rclient, rfactory, rdb):
    upload(rclient)
    provider = FakeProvider([transient_error(), receipt_json()])
    worker.run_next(rfactory, provider)
    mid = reload(rdb)
    assert (mid.extraction_status, mid.extraction_attempts) == ("queued", 1)
    assert mid.extraction_error == "overloaded"  # visible while it waits for the next attempt
    worker.run_next(rfactory, provider)
    assert reload(rdb).extraction_status == "done"
    assert reload(rdb).extraction_error is None


def test_backoff_delays_the_next_attempt(rclient, rfactory, rdb, monkeypatch):
    monkeypatch.setenv("RECEIPTS_EXTRACTION_BACKOFF_S", "3600")
    get_settings.cache_clear()
    upload(rclient)
    provider = FakeProvider([transient_error()])
    assert worker.run_next(rfactory, provider) is True
    assert worker.run_next(rfactory, provider) is False  # not_before is an hour away
    assert rdb.scalar(select(ExtractionJob)).not_before > utcnow()


def test_without_a_credential_nothing_is_claimed(rclient, rfactory, rdb):
    upload(rclient)
    assert worker.run_next(rfactory, None) is False
    job = rdb.scalar(select(ExtractionJob))
    assert (job.status, job.attempts) == ("queued", 0)


def test_deleted_receipts_are_not_extracted(rclient, rfactory, rdb):
    upload(rclient)
    rclient.post(
        f"{BASE}/sync/push",
        json={
            "device_id": "p",
            "receipts": [{"id": RID, "updated_at": FUTURE, "deleted_at": FUTURE}],
        },
    )
    provider = FakeProvider()
    worker.run_next(rfactory, provider)
    assert provider.extract_calls == []
    assert reload(rdb).extraction_status == "done"


# --------------------------------------------------------------------------- restart recovery


def test_a_job_stuck_in_processing_goes_back_to_queued_on_startup(rclient, rfactory, rdb):
    upload(rclient)
    assert worker.claim_next(rfactory) is not None  # claimed, then the server "crashed"
    assert reload(rdb).extraction_status == "processing"
    assert worker.recover_stuck(rfactory, max_attempts=3) == 1
    r = reload(rdb)
    assert (r.extraction_status, r.extraction_attempts) == ("queued", 1)
    worker.run_next(rfactory, FakeProvider())
    assert reload(rdb).extraction_status == "done"


def test_a_job_interrupted_too_often_fails_instead_of_looping(rclient, rfactory, rdb):
    upload(rclient)
    for _ in range(3):
        worker.claim_next(rfactory)
        worker.recover_stuck(rfactory, max_attempts=3)
    r = reload(rdb)
    assert r.extraction_status == "failed" and r.extraction_attempts == 3
    assert "restart" in r.extraction_error


def test_the_worker_thread_recovers_on_start_and_stops(rclient, rfactory, rdb):
    upload(rclient)
    worker.claim_next(rfactory)  # simulated crash
    w = worker.ExtractionWorker(rfactory)
    w.start()  # no credential configured: it recovers the job but leaves it queued
    w.stop()
    r = reload(rdb)
    assert r.extraction_status == "queued" and r.extraction_attempts == 1


# --------------------------------------------------------------------------- retry endpoint


def test_retry_endpoint_requeues_a_failed_extraction(rclient, rfactory, rdb):
    upload(rclient)
    worker.run_next(rfactory, FakeProvider([LLMError("refusal", "no")]))
    assert reload(rdb).extraction_status == "failed"
    r = rclient.post(f"{BASE}/{RID}/extraction/retry")
    assert r.status_code == 202
    assert (r.json()["status"], r.json()["attempts"]) == ("queued", 0)
    assert rclient.post(f"{BASE}/{RID}/extraction/retry").status_code == 409  # already queued
    worker.run_next(rfactory, FakeProvider())
    state = rclient.get(f"{BASE}/{RID}/extraction").json()
    assert (state["status"], state["attempts"], state["last_error"]) == ("done", 1, None)
    assert reload(rdb).store == "Edeka"


def test_retry_needs_a_photo_on_the_server(rclient, rdb):
    rclient.post(
        f"{BASE}/sync/push",
        json={"device_id": "p", "receipts": [{"id": RID, "updated_at": FUTURE}]},
    )
    assert rclient.post(f"{BASE}/{RID}/extraction/retry").status_code == 409
    assert (
        rclient.post(f"{BASE}/7a1f2a3e-1111-4222-8333-444455556666/extraction/retry").status_code
        == 404
    )


def test_retry_of_a_clean_receipt_replaces_its_content(rclient, rfactory, rdb):
    upload(rclient)
    worker.run_next(rfactory, FakeProvider([receipt_json([("Bio Eier 10er", 1, 2.49)])]))
    old_item = rdb.scalar(select(LineItem)).id
    rclient.post(f"{BASE}/{RID}/extraction/retry")
    worker.run_next(rfactory, FakeProvider([receipt_json([("Milch", 2, 1.19)], store="Lidl")]))
    r = reload(rdb)
    assert (r.store, r.total) == ("Lidl", 2.38)
    live = rdb.scalars(select(LineItem).where(LineItem.deleted_at.is_(None))).all()
    assert [i.name_de for i in live] == ["Milch"]
    assert rdb.get(LineItem, old_item).deleted_at is not None  # old row is a tombstone for pull


# --------------------------------------------------------------------------- user edits survive


def push(client, **records):
    r = client.post(f"{BASE}/sync/push", json={"device_id": "phone", **records})
    assert r.status_code == 200, r.text
    return r.json()["results"]


def test_user_edit_is_never_overwritten_by_a_retry(rclient, rfactory, rdb):
    upload(rclient)
    worker.run_next(rfactory, FakeProvider([receipt_json([("Bio Eier 10er", 1, 2.49)])]))
    item = rdb.scalar(select(LineItem))
    results = push(
        rclient,
        receipts=[
            {
                "id": RID,
                "store": "Corner Shop",
                "date": "2026-03-02",
                "total": 2.5,
                "computed_sum": 2.5,
                "reviewed_at": FUTURE,
                "updated_at": FUTURE,
            }
        ],
        line_items=[
            {
                "id": item.id,
                "receipt_id": RID,
                "item_dictionary_id": item.item_dictionary_id,
                "name_de": "Eier",
                "quantity": 1,
                "unit_price": 2.5,
                "total_price": 2.5,
                "updated_at": FUTURE,
            }
        ],
    )
    assert [x["status"] for x in results] == ["applied", "applied"]

    rclient.post(f"{BASE}/{RID}/extraction/retry")
    provider = FakeProvider([receipt_json([("Milch", 3, 9.99)], store="Lidl", date="2026-04-04")])
    worker.run_next(rfactory, provider)

    r = reload(rdb)
    assert (r.store, r.date, r.total, r.computed_sum) == ("Corner Shop", "2026-03-02", 2.5, 2.5)
    assert r.reviewed_at is not None  # still confirmed
    live = rdb.scalars(select(LineItem).where(LineItem.deleted_at.is_(None))).all()
    assert [(i.name_de, i.unit_price) for i in live] == [("Eier", 2.5)]
    assert r.extraction_status == "done"
    assert r.extraction_result["store"] == "Lidl"  # kept for reference only


def test_an_edit_that_arrives_before_the_first_extraction_wins_too(rclient, rfactory, rdb):
    upload(rclient)
    push(rclient, receipts=[{"id": RID, "store": "Typed By Hand", "updated_at": FUTURE}])
    worker.run_next(rfactory, FakeProvider())
    r = reload(rdb)
    assert r.store == "Typed By Hand" and rdb.query(LineItem).count() == 0
    assert r.extraction_status == "done" and r.extraction_result is not None


def test_an_empty_stub_push_is_not_a_user_edit(rclient, rfactory, rdb):
    upload(rclient)
    # an equal/older stub is stale; even a newer one without any content must not block extraction
    # when the receipt did not exist yet (client pushed before uploading the photo)
    other = "7a1f2a3e-1111-4222-8333-444455556666"
    push(rclient, receipts=[{"id": other, "updated_at": "2026-03-01T10:00:00Z"}])
    assert reload(rdb, other).user_edited_at is None
    attached = rclient.put(
        f"{BASE}/{other}/photo", content=make_jpeg(9), headers={"Content-Type": "image/jpeg"}
    )
    assert attached.status_code == 201 and attached.json()["created"] is True  # photo attached
    worker.run_next(rfactory, FakeProvider())
    worker.run_next(rfactory, FakeProvider())
    assert reload(rdb, other).store == "Edeka"


def test_path_numbers_helper_matches_the_prompt(rfactory):
    assert path_number("Other > Miscellaneous > General") > 1
