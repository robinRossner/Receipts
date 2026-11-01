"""Flag fields and taxonomy additions over the sync API: push semantics for old and new clients,
pull, the merged taxonomy, `GET /dictionary?flagged=true`, `/status`, and migration 0002."""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest
from alembic import command
from sqlalchemy import select

from receipts.db.models import ItemDictionary, TaxonomyAddition
from receipts.extraction.taxonomy import get_taxonomy
from tests.receipts_helpers import BASE, alembic_config
from tests.test_receipts_sync import D1, D2, T1, T2, T3, entry, pull, push

FALLBACK = {"category": "Other", "subcategory": "Miscellaneous", "item_group": "General"}
FLAGGED = {
    **FALLBACK,
    "needs_review": True,
    "category_flagged": True,
    "suggested_category": "Pet Food",
    "suggested_parent": "Household",
}


def add(category="Household", subcategory="Pets", item_group="Pet Food", **kw):
    return {"category": category, "subcategory": subcategory, "item_group": item_group, **kw}


def dict_entry(client, id_=D1) -> dict:
    return next(e for e in pull(client)["dictionary"] if e["id"] == id_)


def push_raw(client, **records):
    r = client.post(f"{BASE}/sync/push", json={"device_id": "phone-1", **records})
    assert r.status_code == 200, r.text
    return r.json()["results"]


# --------------------------------------------------------------------------- dictionary fields


def test_pull_has_the_fields_with_defaults(rclient):
    push(rclient, dictionary=[entry()])
    e = dict_entry(rclient)
    assert (e["category_flagged"], e["suggested_category"], e["suggested_parent"]) == (
        False,
        None,
        None,
    )


def test_push_with_all_fields_round_trips(rclient):
    assert push(rclient, dictionary=[entry(**FLAGGED)])[0]["status"] == "applied"
    e = dict_entry(rclient)
    assert e["category_flagged"] is True and e["needs_review"] is True
    assert (e["category"], e["suggested_category"], e["suggested_parent"]) == (
        "Other",
        "Pet Food",
        "Household",
    )


def test_an_old_client_repush_with_the_same_category_keeps_the_flag(rclient):
    push(rclient, dictionary=[entry(**FLAGGED)])
    # no flag keys at all, same category triple, newer clock (e.g. it renamed the display name)
    old = entry(updated=T2, display_name_de="Hundefutter", **FALLBACK, needs_review=True)
    assert push(rclient, dictionary=[old])[0]["status"] == "applied"
    e = dict_entry(rclient)
    assert e["display_name_de"] == "Hundefutter"
    assert e["category_flagged"] is True
    assert (e["suggested_category"], e["suggested_parent"]) == ("Pet Food", "Household")


def test_an_old_client_changing_the_category_resolves_the_flag(rclient):
    push(rclient, dictionary=[entry(**FLAGGED)])
    chosen = entry(updated=T2, is_manual_override=True, needs_review=False)  # Food > Dairy > Milk
    assert push(rclient, dictionary=[chosen])[0]["status"] == "applied"
    e = dict_entry(rclient)
    assert e["category_flagged"] is False and e["needs_review"] is False
    assert (e["suggested_category"], e["suggested_parent"]) == (None, None)
    assert (e["category"], e["item_group"]) == ("Food", "Milk")


def test_a_category_change_without_the_flag_key_clears_even_when_suggestions_are_sent(rclient):
    push(rclient, dictionary=[entry(**FLAGGED)])
    push(rclient, dictionary=[entry(updated=T2, suggested_category="Pet Food")])
    e = dict_entry(rclient)
    assert e["category_flagged"] is False and e["suggested_category"] is None


def test_pushing_flagged_false_clears_the_suggestions(rclient):
    push(rclient, dictionary=[entry(**FLAGGED)])
    resolved = entry(updated=T2, **FALLBACK, category_flagged=False, suggested_category="Pet Food")
    push(rclient, dictionary=[resolved])
    e = dict_entry(rclient)
    assert e["category_flagged"] is False
    assert (e["suggested_category"], e["suggested_parent"]) == (None, None)
    assert (e["category"], e["subcategory"]) == ("Other", "Miscellaneous")  # explicit: kept


def test_new_clients_can_resolve_with_the_full_set_of_fields(rclient):
    push(rclient, dictionary=[entry(**FLAGGED)])
    resolved = entry(
        updated=T2,
        is_manual_override=True,
        needs_review=False,
        category_flagged=False,
        suggested_category=None,
        suggested_parent=None,
    )
    push(rclient, dictionary=[resolved])
    e = dict_entry(rclient)
    assert (e["is_manual_override"], e["needs_review"], e["category_flagged"]) == (
        True,
        False,
        False,
    )


def test_suggestions_alone_follow_the_stored_flag(rclient):
    push(rclient, dictionary=[entry(**FLAGGED)])
    # only the suggestion keys: updated while the entry stays flagged; null clears just that one
    push(
        rclient,
        dictionary=[
            entry(updated=T2, **FALLBACK, suggested_category="Cat Litter", suggested_parent=None)
        ],
    )
    e = dict_entry(rclient)
    assert e["category_flagged"] is True
    assert (e["suggested_category"], e["suggested_parent"]) == ("Cat Litter", None)


def test_suggestions_are_normalised_and_cut_to_80_chars(rclient):
    long = "x" * 120
    push(
        rclient,
        dictionary=[
            entry(**{**FLAGGED, "suggested_category": f"  {long} ", "suggested_parent": "  "})
        ],
    )
    e = dict_entry(rclient)
    assert e["suggested_category"] == "x" * 80 and e["suggested_parent"] is None
    # flag false from the start: suggestions never stored
    push(rclient, dictionary=[entry(D2, "brot", category_flagged=False, suggested_category="Z")])
    assert dict_entry(rclient, D2)["suggested_category"] is None


def test_null_flag_counts_as_absent(rclient):
    push(rclient, dictionary=[entry(**FLAGGED)])
    push(rclient, dictionary=[entry(updated=T2, **FALLBACK, category_flagged=None)])
    assert dict_entry(rclient)["category_flagged"] is True


def test_stale_pushes_do_not_touch_the_flag(rclient):
    push(rclient, dictionary=[entry(updated=T2, **FLAGGED)])
    assert (
        push(rclient, dictionary=[entry(updated=T1, category_flagged=False)])[0]["status"]
        == "stale"
    )
    assert dict_entry(rclient)["category_flagged"] is True


def test_resolution_reaches_clients_through_pull(rclient):
    push(rclient, dictionary=[entry(**FLAGGED)])
    cursor = pull(rclient)["cursor"]
    push(rclient, dictionary=[entry(updated=T2, category_flagged=False)])
    page = pull(rclient, cursor)
    assert [e["id"] for e in page["dictionary"]] == [D1]
    assert page["dictionary"][0]["category_flagged"] is False


def test_flag_only_changes_bump_the_change_sequence(rdb):
    d = ItemDictionary(canonical_name="hundefutter", category_flagged=True)
    rdb.add(d)
    rdb.commit()
    rdb.refresh(d)
    for column, value in (
        ("category_flagged", False),
        ("suggested_category", "Pet Food"),
        ("suggested_parent", "Household"),
    ):
        before = d.server_seq
        setattr(d, column, value)
        rdb.commit()
        rdb.refresh(d)
        assert d.server_seq > before, column


# --------------------------------------------------------------------------- listing


def test_dictionary_listing_filters_flagged_and_status_counts_them(rclient):
    push(
        rclient,
        dictionary=[
            entry(D1, "hundefutter", **FLAGGED),
            entry(D2, "milch"),
            entry("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "katzenstreu", **FLAGGED),
            entry(
                "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                "geloescht",
                **FLAGGED,
                deleted_at=T1,
            ),
        ],
    )
    everything = rclient.get(f"{BASE}/dictionary").json()
    assert everything["count"] == 3 and "category_flagged" in everything["entries"][0]
    flagged = rclient.get(f"{BASE}/dictionary", params={"flagged": "true"}).json()
    assert [e["canonical_name"] for e in flagged["entries"]] == ["hundefutter", "katzenstreu"]
    assert flagged["count"] == 2
    both = rclient.get(f"{BASE}/dictionary", params={"flagged": "true", "include_deleted": "true"})
    assert both.json()["count"] == 2  # tombstones are never "to resolve"
    assert rclient.get(f"{BASE}/status").json()["flagged_items"] == 2
    push(rclient, dictionary=[entry(D1, "hundefutter", updated=T3, category_flagged=False)])
    assert rclient.get(f"{BASE}/status").json()["flagged_items"] == 1


def test_status_without_flags_is_zero(rclient):
    assert rclient.get(f"{BASE}/status").json()["flagged_items"] == 0


# --------------------------------------------------------------------------- taxonomy additions


def test_additions_round_trip_through_push_and_pull(rclient):
    results = push(rclient, taxonomy_additions=[add(created_at=T1)])
    assert results == [
        {
            "entity": "taxonomy_addition",
            "id": "Household > Pets > Pet Food",
            "status": "applied",
            "reason": None,
        }
    ]
    page = pull(rclient)
    wire = add(created_at="2026-05-01T10:00:00.000Z")  # the client's clock is kept
    assert page["taxonomy_additions"] == [wire]
    # every response carries all additions (no cursor), also an incremental one
    assert pull(rclient, page["cursor"])["taxonomy_additions"] == [wire]
    assert (
        push(rclient, taxonomy_additions=[add("Household", "Pets", "Pet Toys")])[0]["status"]
        == "applied"
    )
    groups = [a["item_group"] for a in pull(rclient)["taxonomy_additions"]]
    assert groups == ["Pet Food", "Pet Toys"]  # created_at, id order


def test_old_clients_see_no_change_in_results_and_an_extra_pull_key_only(rclient):
    results = push(rclient, dictionary=[entry()])
    assert [r["entity"] for r in results] == ["dictionary"]
    assert pull(rclient)["taxonomy_additions"] == []


@pytest.mark.parametrize(
    "path",
    [
        ("Food", "Dairy & Eggs", "Milk"),
        ("food", "dairy & eggs", "MILK"),
        ("Household", "Pets", "Pet Food"),  # already added
        ("HOUSEHOLD", "PETS", "pet food"),
    ],
)
def test_existing_paths_are_stale(rclient, path):
    push(rclient, taxonomy_additions=[add()])
    result = push(rclient, taxonomy_additions=[add(*path)])[0]
    assert result["status"] == "stale" and result["id"] == " > ".join(path)
    assert len(pull(rclient)["taxonomy_additions"]) == 1


@pytest.mark.parametrize(
    "bad",
    [
        add(category=""),
        add(subcategory="   "),
        add(item_group=""),
        add(item_group="x" * 61),
        add(category="A > B"),
        add(subcategory="Pe\nts"),
        add(item_group="Pet\x00Food"),
        {"category": "Household", "subcategory": "Pets"},
        {"category": 1, "subcategory": 2, "item_group": 3},
    ],
)
def test_malformed_additions_are_rejected(rclient, bad):
    result = push(rclient, taxonomy_additions=[bad])[0]
    assert result["entity"] == "taxonomy_addition" and result["status"] == "rejected"
    assert pull(rclient)["taxonomy_additions"] == []


def test_parts_are_trimmed_and_60_chars_are_fine(rclient):
    result = push(rclient, taxonomy_additions=[add("  Household ", " Pets ", "p" * 60)])[0]
    assert result["status"] == "applied" and result["id"] == "Household > Pets > " + "p" * 60
    assert pull(rclient)["taxonomy_additions"][0]["subcategory"] == "Pets"


def test_at_most_300_additions(rclient, rdb):
    rdb.add_all(
        TaxonomyAddition(category="Household", subcategory="Bulk", item_group=f"G{i}")
        for i in range(300)
    )
    rdb.commit()
    result = push(rclient, taxonomy_additions=[add()])[0]
    assert result["status"] == "rejected" and "300" in result["reason"]
    assert (
        push(rclient, taxonomy_additions=[add("Household", "Bulk", "G5")])[0]["status"] == "stale"
    )


def test_results_list_additions_first(rclient):
    results = push(
        rclient,
        dictionary=[entry(category="Household", subcategory="Pets", item_group="Pet Food")],
        taxonomy_additions=[add(), add(item_group="")],
    )
    assert [(r["entity"], r["status"]) for r in results] == [
        ("taxonomy_addition", "applied"),
        ("taxonomy_addition", "rejected"),
        ("dictionary", "applied"),
    ]


def test_a_dictionary_entry_may_use_a_path_added_in_the_same_request(rclient):
    pets = {"category": "Household", "subcategory": "Pets", "item_group": "Pet Food"}
    # without the addition the path is unknown
    first = push(rclient, dictionary=[entry(**pets)])[0]
    assert first["status"] == "rejected" and "unknown category path" in first["reason"]
    results = push(rclient, taxonomy_additions=[add()], dictionary=[entry(**pets)])
    assert [r["status"] for r in results] == ["applied", "applied"]
    assert dict_entry(rclient)["subcategory"] == "Pets"
    # and later requests too (the merged taxonomy is read per request)
    assert push(rclient, dictionary=[entry(D2, "katzenfutter", **pets)])[0]["status"] == "applied"


def test_merged_taxonomy_endpoint_and_version(rclient):
    base = get_taxonomy()
    plain = rclient.get(f"{BASE}/taxonomy").json()
    assert plain["version"] == base.version == pull(rclient)["taxonomy_version"]
    assert rclient.get(f"{BASE}/dictionary").json()["taxonomy_version"] == base.version

    push(
        rclient,
        taxonomy_additions=[
            add("Household", "Pets", "Pet Food"),  # new subcategory in an existing category
            add("household", "pets", "Pet Toys"),  # appended to the subcategory above
            add("Household", "Cleaning", "Oven Cleaner"),  # new group in an existing subcategory
            add("Garden", "Plants", "Seeds"),  # new category
            add("Food", "Dairy & Eggs", "Milk Powder"),
        ],
    )
    merged = rclient.get(f"{BASE}/taxonomy").json()
    assert merged["version"] != base.version
    assert merged["version"] == pull(rclient)["taxonomy_version"]
    assert merged["version"] == rclient.get(f"{BASE}/dictionary").json()["taxonomy_version"]
    cats = {
        c["name"]: {s["name"]: s["item_groups"] for s in c["subcategories"]}
        for c in merged["categories"]
    }
    assert [c["name"] for c in merged["categories"]] == [
        "Food",
        "Household",
        "Personal Care",
        "Other",
        "Garden",
    ]
    assert cats["Household"]["Pets"] == ["Pet Food", "Pet Toys"]
    assert cats["Household"]["Cleaning"][-1] == "Oven Cleaner"
    assert list(cats["Household"])[-1] == "Pets"  # appended at the end
    assert cats["Garden"] == {"Plants": ["Seeds"]}
    assert cats["Food"]["Dairy & Eggs"][-1] == "Milk Powder"
    # the cached base is untouched, and the version changes again with another addition
    assert get_taxonomy().version == base.version and "Garden" not in dict(
        get_taxonomy().categories
    )
    push(rclient, taxonomy_additions=[add("Garden", "Plants", "Bulbs")])
    assert rclient.get(f"{BASE}/taxonomy").json()["version"] != merged["version"]


def test_additions_never_enter_the_change_sequence(rclient):
    cursor = pull(rclient)["cursor"]
    push(rclient, taxonomy_additions=[add()])
    page = pull(rclient, cursor)
    assert page["cursor"] == cursor and page["dictionary"] == page["receipts"] == []
    assert len(page["taxonomy_additions"]) == 1


def test_the_unique_index_backs_the_case_insensitive_rule(rdb):
    from sqlalchemy.exc import IntegrityError

    rdb.add(TaxonomyAddition(category="Household", subcategory="Pets", item_group="Pet Food"))
    rdb.commit()
    rdb.add(TaxonomyAddition(category="HOUSEHOLD", subcategory="pets", item_group="pet food"))
    with pytest.raises(IntegrityError):
        rdb.commit()
    rdb.rollback()
    assert len(rdb.scalars(select(TaxonomyAddition)).all()) == 1


# --------------------------------------------------------------------------- migration 0002


def _columns(path: Path, table: str) -> set[str]:
    with sqlite3.connect(path) as db:
        return {r[1] for r in db.execute(f"PRAGMA table_info({table})")}


def _db_at_0001(tmp_path):
    url = f"sqlite:///{tmp_path / 'old.db'}"
    cfg = alembic_config(url)
    command.upgrade(cfg, "0001")
    path = tmp_path / "old.db"
    with sqlite3.connect(path) as db:
        db.execute(
            "INSERT INTO item_dictionary (id, canonical_name, category, subcategory, item_group,"
            " aliases, is_manual_override, needs_review, times_seen, created_at, updated_at)"
            " VALUES ('d1', 'milch', 'Food', 'Dairy & Eggs', 'Milk', '[\"vollmilch\"]', 1, 0, 3,"
            " '2026-03-01 10:00:00', '2026-03-01 10:00:00')"
        )
        db.execute(
            "INSERT INTO receipts (id, store, needs_review, review_reasons, created_at, updated_at,"
            " photo_location, extraction_status, extraction_attempts)"
            " VALUES ('r1', 'Edeka', 0, '[]', '2026-03-01 10:00:00', '2026-03-01 10:00:00',"
            " 'none', 'done', 1)"
        )
    return cfg, path


def test_0002_keeps_old_rows_and_extends_the_triggers(tmp_path):
    cfg, path = _db_at_0001(tmp_path)
    assert "category_flagged" not in _columns(path, "item_dictionary")
    with sqlite3.connect(path) as db:
        seq_before = db.execute("SELECT server_seq FROM item_dictionary").fetchone()[0]
        n_before = db.execute("SELECT count(*) FROM sync_seq").fetchone()[0]

    command.upgrade(cfg, "head")
    assert {"category_flagged", "suggested_category", "suggested_parent"} <= _columns(
        path, "item_dictionary"
    )
    assert "taxonomy_additions" in {
        r[0] for r in sqlite3.connect(path).execute("SELECT name FROM sqlite_master")
    }
    with sqlite3.connect(path) as db:
        row = db.execute(
            "SELECT canonical_name, category, aliases, is_manual_override, times_seen,"
            " category_flagged, suggested_category, suggested_parent, server_seq"
            " FROM item_dictionary"
        ).fetchone()
        assert row == ("milch", "Food", '["vollmilch"]', 1, 3, 0, None, None, seq_before)
        assert db.execute("SELECT store FROM receipts").fetchone() == ("Edeka",)
        assert db.execute("SELECT count(*) FROM sync_seq").fetchone()[0] == n_before  # no rewrite
        # the insert trigger is still there, and a flag-only change bumps the sequence
        for column, value in (
            ("category_flagged", 1),
            ("suggested_category", "'Pet Food'"),
            ("suggested_parent", "'Household'"),
        ):
            before = db.execute("SELECT server_seq FROM item_dictionary").fetchone()[0]
            db.execute(f"UPDATE item_dictionary SET {column} = {value}")
            assert db.execute("SELECT server_seq FROM item_dictionary").fetchone()[0] > before
        before = db.execute("SELECT server_seq FROM item_dictionary").fetchone()[0]
        db.execute("UPDATE item_dictionary SET times_seen = 9")  # still not a change
        assert db.execute("SELECT server_seq FROM item_dictionary").fetchone()[0] == before
        db.execute(
            "INSERT INTO item_dictionary (id, canonical_name, aliases, is_manual_override,"
            " needs_review, times_seen, created_at, updated_at)"
            " VALUES ('d2', 'brot', '[]', 0, 0, 1, '2026-03-01', '2026-03-01')"
        )
        assert (
            db.execute(
                "SELECT server_seq, category_flagged FROM item_dictionary WHERE id='d2'"
            ).fetchone()[0]
            > before
        )


def test_0002_can_be_applied_to_a_database_that_already_has_the_columns(tmp_path):
    cfg, path = _db_at_0001(tmp_path)
    command.upgrade(cfg, "head")
    command.stamp(cfg, "0001")  # as if a previous run died after the DDL
    command.upgrade(cfg, "head")
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT version_num FROM alembic_version").fetchone() == ("0002",)
        assert db.execute("SELECT count(*) FROM item_dictionary").fetchone() == (1,)


def test_0002_downgrades_to_0001_and_back(tmp_path):
    cfg, path = _db_at_0001(tmp_path)
    command.upgrade(cfg, "head")
    with sqlite3.connect(path) as db:
        db.execute("UPDATE item_dictionary SET category_flagged = 1")
    command.downgrade(cfg, "0001")
    cols = _columns(path, "item_dictionary")
    assert not {"category_flagged", "suggested_category", "suggested_parent"} & cols
    assert "taxonomy_additions" not in {
        r[0] for r in sqlite3.connect(path).execute("SELECT name FROM sqlite_master")
    }
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT canonical_name FROM item_dictionary").fetchone() == ("milch",)
        before = db.execute("SELECT server_seq FROM item_dictionary").fetchone()[0]
        db.execute("UPDATE item_dictionary SET category = 'Household'")  # 0001 trigger is back
        assert db.execute("SELECT server_seq FROM item_dictionary").fetchone()[0] > before
    command.upgrade(cfg, "head")
    assert "category_flagged" in _columns(path, "item_dictionary")
