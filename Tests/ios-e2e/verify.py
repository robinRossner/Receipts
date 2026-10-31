"""Checks what the e2e backend holds (stdin: the sync/pull JSON of `server.sh status`).

    server.sh status | python3 verify.py edited      # the phone's edit and confirmation arrived
    server.sh status | python3 verify.py archived     # the Mac archived the photos
"""
import json
import sys

mode = sys.argv[1]
data = json.load(sys.stdin)
receipts = {r["id"]: r for r in data["receipts"] if not r["deleted_at"]}
items = [i for i in data["line_items"] if not i["deleted_at"]]
ok = True


def check(cond, text):
    global ok
    print(("ok   " if cond else "FAIL ") + text)
    ok = ok and cond


if mode == "edited":
    edeka = [r for r in receipts.values() if r["store"] == "Edeka"]
    check(len(edeka) >= 1, f"{len(edeka)} Edeka receipt(s) extracted")
    confirmed = [r for r in edeka if r["reviewed_at"]]
    check(len(confirmed) == 1, "exactly one receipt confirmed from the phone (reviewed_at set)")
    if confirmed:
        prices = sorted(i["unit_price"] for i in items if i["receipt_id"] == confirmed[0]["id"])
        check(2.59 in prices, f"edited unit price 2.59 reached the server (unit prices {prices})")
elif mode == "archived":
    check(all(r["photo_location"] == "archived" for r in receipts.values() if r["extraction_status"] == "done"),
          "every finished receipt's photo is archived")
    check(all(r["archived_at"] for r in receipts.values() if r["photo_location"] == "archived"), "archived_at recorded")
sys.exit(0 if ok else 1)
