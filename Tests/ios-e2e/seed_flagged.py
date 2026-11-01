#!/usr/bin/env python3
"""Seeds a local throwaway e2e backend (Tests/ios-e2e/server.sh) with flagged items, through its public sync API.

    python3 Tests/ios-e2e/seed_flagged.py PORT TOKEN          # the data FlagFlowTests and a Mac run work on
    python3 Tests/ios-e2e/seed_flagged.py PORT TOKEN verify   # after FlagFlowTests: what the server must hold now

Never point this at anything but the throwaway server: it pushes test records.
"""
import datetime as dt
import json
import sys
import urllib.request
import uuid

port, token = sys.argv[1], sys.argv[2]
BASE = f"http://127.0.0.1:{port}/api/v1/receipts"
FALLBACK = ("Other", "Miscellaneous", "General")
# Pushed as if from another device, so the phone only learns it through a pull. "|" on purpose: any name must chart.
SYNCED_PATH = ("Arts | Crafts", "Knitting", "Yarn")


def call(path, body=None):
    req = urllib.request.Request(
        f"{BASE}{path}",
        json.dumps(body).encode() if body is not None else None,
        {"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    return json.load(urllib.request.urlopen(req))


def seed():
    now = dt.datetime.now(dt.timezone.utc)
    stamp = now.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    today = dt.date.today()  # the local date: receipts must fall in the month the Overview opens on

    def day(n):
        return max(today - dt.timedelta(days=n), today.replace(day=1)).isoformat()

    dictionary, ids = [], {}

    def entry(de, en, path=FALLBACK, suggested=None, parent=None, flagged=False):
        u = str(uuid.uuid4())
        ids[de] = u
        dictionary.append({
            "id": u, "canonical_name": de.lower(), "display_name_de": de, "translation_en": en,
            "category": path[0], "subcategory": path[1], "item_group": path[2], "aliases": [de.lower()],
            "is_manual_override": False, "needs_review": flagged, "category_flagged": flagged,
            "suggested_category": suggested, "suggested_parent": parent, "updated_at": stamp,
        })

    entry("Pedigree Hundefutter", "Dog food", suggested="Dog Supplies", parent="Household > Pets", flagged=True)
    entry("Trixie Kauknochen", "Dog chews", suggested="Dog Supplies", parent="Household > Pets", flagged=True)
    entry("Angelrute", "Fishing rod", suggested="Fishing Gear", parent="Sports", flagged=True)
    entry("Modellierknete", "Modelling clay", suggested="Clay", parent="Crafts", flagged=True)
    entry("Seltsames Ding", "Odd thing", flagged=True)
    entry("Vollmilch 1L", "Whole milk 1L", ("Food", "Dairy & Eggs", "Milk"))
    entry("Sockenwolle", "Sock yarn", SYNCED_PATH)

    receipts, lines = [], []

    def receipt(store, date, items):
        rid = str(uuid.uuid4())
        total = round(sum(p for _, p in items), 2)
        receipts.append({
            "id": rid, "store": store, "date": date, "time": "18:42", "total": total, "computed_sum": total,
            "needs_review": False, "review_reasons": [], "reviewed_at": None, "created_at": date + "T12:00:00Z",
            "updated_at": stamp, "deleted_at": None, "photo_location": "none",
        })
        for pos, (name, price) in enumerate(items):
            lines.append({
                "id": str(uuid.uuid4()), "receipt_id": rid, "item_dictionary_id": ids[name], "position": pos,
                "raw_text": name, "name_de": name, "quantity": 1, "unit_price": price, "total_price": price,
                "price_normalized": False, "updated_at": stamp, "deleted_at": None,
            })

    receipt("Fressnapf", day(1), [("Pedigree Hundefutter", 12.99), ("Trixie Kauknochen", 4.50)])
    receipt("Fressnapf", day(5), [("Pedigree Hundefutter", 12.99)])
    receipt("Decathlon", day(2), [("Angelrute", 39.00), ("Seltsames Ding", 3.00)])
    receipt("Idee", day(3), [("Modellierknete", 6.20), ("Sockenwolle", 8.90)])
    receipt("Edeka", day(4), [("Vollmilch 1L", 1.19)])

    result = call("/sync/push", {
        "device_id": "seed-script", "dictionary": dictionary, "receipts": receipts, "line_items": lines,
        "taxonomy_additions": [{"category": SYNCED_PATH[0], "subcategory": SYNCED_PATH[1], "item_group": SYNCED_PATH[2], "created_at": stamp}],
    })
    bad = [r for r in result["results"] if r["status"] != "applied"]
    print("pushed", len(result["results"]), "bad:", bad[:5])
    sys.exit(1 if bad else 0)


def verify():
    """What FlagFlowTests leaves behind, read back from the server."""
    entries = {e["display_name_de"]: e for e in call("/sync/pull?since=")["dictionary"]}
    flagged = call("/dictionary?flagged=true")
    additions = call("/taxonomy")
    problems = []
    still = flagged if isinstance(flagged, list) else flagged.get("items", flagged.get("entries", []))
    if still:
        problems.append(f"still flagged on the server: {still}")
    expected = {
        "Pedigree Hundefutter": ("Household", "Pets", "Dog Supplies"),
        "Trixie Kauknochen": ("Household", "Pets", "Dog Supplies"),
        "Angelrute": ("Sports", "Outdoors", "Fishing Gear"),
        "Modellierknete": SYNCED_PATH,
        "Seltsames Ding": FALLBACK,
    }
    for name, path in expected.items():
        e = entries[name]
        got = (e["category"], e["subcategory"], e["item_group"])
        if got != path:
            problems.append(f"{name}: {got} != {path}")
        if e["category_flagged"] or e["suggested_category"] or e["suggested_parent"] or e["needs_review"] or not e["is_manual_override"]:
            problems.append(f"{name}: flag or suggestion left: {e}")
    tree = json.dumps(additions)
    for part in ["Dog Supplies", "Fishing Gear", "Outdoors", "Yarn"]:
        if part not in tree:
            problems.append(f"{part} is not in the server's taxonomy")
    print("VERIFY", "ok" if not problems else problems)
    sys.exit(1 if problems else 0)


verify() if len(sys.argv) > 3 and sys.argv[3] == "verify" else seed()
