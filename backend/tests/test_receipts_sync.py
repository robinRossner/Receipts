"""Offline-first sync: push (last-write-wins by client `updated_at`, tombstones, per-record
rejection, server-owned fields) and pull (server change sequence, paging, deletes)."""

from __future__ import annotations

from receipts.db.models import Receipt
from tests.receipts_helpers import BASE, make_jpeg

R1 = "11111111-1111-4111-8111-111111111111"
R2 = "22222222-2222-4222-8222-222222222222"
D1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
D2 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
L1 = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
T1, T2, T3 = "2026-05-01T10:00:00Z", "2026-05-01T11:00:00Z", "2026-05-01T12:00:00Z"


def push(client, **records):
    r = client.post(f"{BASE}/sync/push", json={"device_id": "phone-1", **records})
    assert r.status_code == 200, r.text
    return r.json()["results"]


def pull(client, since=""):
    r = client.get(f"{BASE}/sync/pull", params={"since": since})
    assert r.status_code == 200, r.text
    return r.json()


def receipt(id_=R1, updated=T1, **kw):
    return {
        "id": id_,
        "store": "Edeka",
        "date": "2026-04-30",
        "total": 5.0,
        "updated_at": updated,
        **kw,
    }


def entry(id_=D1, name="milch", updated=T1, **kw):
    return {
        "id": id_,
        "canonical_name": name,
        "display_name_de": "Milch",
        "category": "Food",
        "subcategory": "Dairy & Eggs",
        "item_group": "Milk",
        "updated_at": updated,
        **kw,
    }


def item(id_=L1, rid=R1, did=D1, updated=T1, **kw):
    return {
        "id": id_,
        "receipt_id": rid,
        "item_dictionary_id": did,
        "name_de": "Milch",
        "quantity": 1,
        "unit_price": 1.19,
        "total_price": 1.19,
        "updated_at": updated,
        **kw,
    }


def statuses(results):
    return [r["status"] for r in results]


# --------------------------------------------------------------------------- last write wins


def test_push_creates_records_and_pull_returns_them(rclient):
    res = push(rclient, dictionary=[entry()], receipts=[receipt()], line_items=[item()])
    assert statuses(res) == ["applied"] * 3
    page = pull(rclient)
    assert [r["id"] for r in page["receipts"]] == [R1]
    assert (
        page["receipts"][0]["store"] == "Edeka" and page["receipts"][0]["photo_location"] == "none"
    )
    assert [d["canonical_name"] for d in page["dictionary"]] == ["milch"]
    assert page["line_items"][0]["unit_price"] == 1.19
    assert page["has_more"] is False and page["cursor"].startswith("c")


def test_newer_wins_older_and_equal_are_stale(rclient):
    push(rclient, receipts=[receipt(updated=T2, store="Rewe")])
    assert statuses(push(rclient, receipts=[receipt(updated=T1, store="Old")])) == ["stale"]
    assert statuses(push(rclient, receipts=[receipt(updated=T2, store="Same Time")])) == ["stale"]
    assert pull(rclient)["receipts"][0]["store"] == "Rewe"
    assert statuses(push(rclient, receipts=[receipt(updated=T3, store="Lidl")])) == ["applied"]
    assert pull(rclient)["receipts"][0]["store"] == "Lidl"


def test_repushing_a_payload_is_a_noop(rclient):
    payload = {"dictionary": [entry()], "receipts": [receipt()], "line_items": [item()]}
    push(rclient, **payload)
    cursor = pull(rclient)["cursor"]
    assert statuses(push(rclient, **payload)) == ["stale"] * 3
    again = pull(rclient, cursor)
    assert (again["receipts"], again["line_items"], again["dictionary"]) == ([], [], [])


def test_review_status_syncs(rclient):
    push(
        rclient, receipts=[receipt(needs_review=True, review_reasons=["No total found on receipt"])]
    )
    rec = pull(rclient)["receipts"][0]
    assert rec["needs_review"] is True and rec["review_reasons"] == ["No total found on receipt"]
    assert rec["reviewed_at"] is None
    push(rclient, receipts=[receipt(updated=T2, needs_review=False, reviewed_at=T2)])
    rec = pull(rclient)["receipts"][0]
    assert rec["reviewed_at"] == T2.replace("Z", ".000Z") and rec["needs_review"] is False


# --------------------------------------------------------------------------- tombstones


def test_deletes_are_tombstones_that_pull_delivers(rclient, rdb):
    push(rclient, dictionary=[entry()], receipts=[receipt()], line_items=[item()])
    cursor = pull(rclient)["cursor"]
    res = push(
        rclient,
        receipts=[receipt(updated=T2, deleted_at=T2)],
        line_items=[item(updated=T2, deleted_at=T2)],
    )
    assert statuses(res) == ["applied", "applied"]
    after = pull(rclient, cursor)
    assert after["receipts"][0]["deleted_at"] == T2.replace("Z", ".000Z")
    assert after["line_items"][0]["deleted_at"] == T2.replace("Z", ".000Z")
    assert rdb.query(Receipt).count() == 1  # the row is still there


def test_a_stale_undelete_does_not_resurrect_and_a_newer_one_does(rclient):
    push(rclient, receipts=[receipt(updated=T2, deleted_at=T2)])
    assert statuses(push(rclient, receipts=[receipt(updated=T1)])) == ["stale"]
    assert pull(rclient)["receipts"][0]["deleted_at"] is not None
    assert statuses(push(rclient, receipts=[receipt(updated=T3)])) == ["applied"]
    assert pull(rclient)["receipts"][0]["deleted_at"] is None


def test_a_merged_away_dictionary_entry_frees_its_name(rclient):
    push(rclient, dictionary=[entry(D1, "milch")])
    res = push(rclient, dictionary=[entry(D2, "milch")])
    assert res[0]["status"] == "rejected" and "already used" in res[0]["reason"]
    push(rclient, dictionary=[entry(D1, "milch", updated=T2, deleted_at=T2)])
    assert statuses(push(rclient, dictionary=[entry(D2, "milch")])) == ["applied"]


# --------------------------------------------------------------------------- validation


def test_bad_records_are_rejected_alone(rclient):
    res = push(
        rclient,
        receipts=[
            receipt(R1),
            {"id": "nope", "updated_at": T1},
            receipt(R2, date="31.12.2026"),
            receipt("33333333-3333-4333-8333-333333333333", time="9:5"),
        ],
        line_items=[
            item(L1, rid="99999999-9999-4999-8999-999999999999"),  # unknown receipt
            item("dddddddd-dddd-4ddd-8ddd-dddddddddddd", did=D2),  # unknown dictionary entry
        ],
    )
    assert statuses(res) == ["applied", "rejected", "rejected", "rejected", "rejected", "rejected"]
    assert (
        "unknown receipt_id" in res[4]["reason"]
        and "unknown item_dictionary_id" in res[5]["reason"]
    )
    assert [r["id"] for r in pull(rclient)["receipts"]] == [R1]


def test_category_paths_must_exist_in_the_taxonomy(rclient):
    res = push(rclient, dictionary=[entry(subcategory="Dairy & Eggs", item_group="Moon Cheese")])
    assert res[0]["status"] == "rejected" and "unknown category path" in res[0]["reason"]


def test_server_owned_fields_cannot_be_pushed(rclient, rdb):
    rclient.put(f"{BASE}/{R1}/photo", content=make_jpeg(1), headers={"Content-Type": "image/jpeg"})
    before = pull(rclient)["receipts"][0]
    push(
        rclient,
        receipts=[
            receipt(
                updated="2099-01-01T00:00:00Z",
                photo_location="archived",
                photo_sha256="0" * 64,
                extraction_status="done",
                archived_at=T3,
            )
        ],
    )
    after = pull(rclient)["receipts"][0]
    for key in (
        "photo_location",
        "photo_sha256",
        "extraction_status",
        "archived_at",
        "photo_bytes",
    ):
        assert after[key] == before[key], key
    assert after["store"] == "Edeka"  # the editable part did apply


def test_a_receipt_pushed_as_archived_has_no_photo_to_upload(rclient):
    """Mac migration: the photo already lives on the archive device."""
    push(rclient, receipts=[receipt(photo_location="archived")])
    rec = pull(rclient)["receipts"][0]
    assert rec["photo_location"] == "archived" and rec["archived_at"] is not None
    r = rclient.put(
        f"{BASE}/{R1}/photo", content=make_jpeg(2), headers={"Content-Type": "image/jpeg"}
    )
    assert r.status_code == 409 and r.json()["detail"]["code"] == "photo_archived"
    assert rclient.get(f"{BASE}/{R1}/photo").status_code == 410


def test_line_item_cannot_move_to_another_receipt(rclient):
    push(rclient, dictionary=[entry()], receipts=[receipt(R1), receipt(R2)], line_items=[item()])
    res = push(rclient, line_items=[item(rid=R2, updated=T2)])
    assert res[0]["status"] == "rejected"


# --------------------------------------------------------------------------- pull cursor


def test_pull_pages_by_server_sequence(rclient):
    push(
        rclient,
        dictionary=[entry()],
        receipts=[receipt(R1), receipt(R2)],
        line_items=[item()],
    )
    seen: list[str] = []
    cursor = ""
    pages = 0
    while True:
        r = rclient.get(f"{BASE}/sync/pull", params={"since": cursor, "limit": 2}).json()
        pages += 1
        seen += [x["id"] for key in ("dictionary", "receipts", "line_items") for x in r[key]]
        cursor = r["cursor"]
        if not r["has_more"]:
            break
    assert pages == 2 and sorted(seen) == sorted([D1, R1, R2, L1])
    assert pull(rclient, cursor)["receipts"] == []  # nothing new after the last cursor


def test_changes_after_the_cursor_come_again_exactly_once(rclient):
    push(rclient, receipts=[receipt(R1)])
    cursor = pull(rclient)["cursor"]
    push(rclient, receipts=[receipt(R1, updated=T2, store="Lidl"), receipt(R2)])
    page = pull(rclient, cursor)
    assert sorted(r["id"] for r in page["receipts"]) == [R1, R2]
    assert pull(rclient, page["cursor"])["receipts"] == []


def test_server_side_changes_bump_the_cursor_without_a_client_clock(rclient, rdb):
    rclient.put(f"{BASE}/{R1}/photo", content=make_jpeg(3), headers={"Content-Type": "image/jpeg"})
    cursor = pull(rclient)["cursor"]
    rdb.get(Receipt, R1).extraction_error = "touched by the server"
    rdb.commit()
    page = pull(rclient, cursor)
    assert page["receipts"][0]["extraction_error"] == "touched by the server"


def test_bad_cursor_is_a_400(rclient):
    r = rclient.get(f"{BASE}/sync/pull", params={"since": "garbage"})
    assert r.status_code == 400 and r.json()["detail"]["code"] == "bad_cursor"


def test_taxonomy_and_dictionary_endpoints(rclient):
    tax = rclient.get(f"{BASE}/taxonomy").json()
    assert tax["categories"][0]["name"] == "Food"
    assert tax["categories"][0]["subcategories"][0] == {
        "name": "Vegetables",
        "item_groups": [
            "Tomatoes",
            "Leafy Greens",
            "Root Vegetables",
            "Peppers",
            "Onions & Garlic",
            "Mushrooms",
            "Cucumbers, Squash & Eggplant",
            "Herbs & Aromatics",
            "Cabbage & Brassicas",
            "Other Vegetables",
        ],
    }
    assert pull(rclient)["taxonomy_version"] == tax["version"]
    # a subcategory without groups still offers "General", like the Mac app
    other = next(c for c in tax["categories"] if c["name"] == "Other")
    assert {"name": "Miscellaneous", "item_groups": ["General"]} in other["subcategories"]
    push(rclient, dictionary=[entry(), entry(D2, "alt", deleted_at=T2, updated=T2)])
    d = rclient.get(f"{BASE}/dictionary").json()
    assert d["count"] == 1 and d["entries"][0]["canonical_name"] == "milch"
    assert (
        rclient.get(f"{BASE}/dictionary", params={"include_deleted": "true"}).json()["count"] == 2
    )
