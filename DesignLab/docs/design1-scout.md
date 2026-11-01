# Design 1 (Polish): scout notes

## The identity to keep

- **Paper on a desk.** `paper` cards on a darker `desk`, hairline `rule` borders, small corners. Dark mode is dark paper
  with light ink, not a black-and-grey system look.
- **Three inks.** Ink for content and tint, pen red for "look at this", stamp green for "done".
- **Three type voices.** American Typewriter for names and headings, SF Mono for money, dates and quantities, SF Pro for
  everything else. Small uppercase section labels.
- **The structure.** Three tabs, banners above them, list with Needs review / Reviewed / Recently deleted, red left edge on
  unreviewed rows, detail with Items / Photo and a fixed action bar with the green `Looks good`, `Total`, charts and tree
  on Overview, a grouped form in Settings. No new screens, no moved features.

## Weaknesses found in the code, and the change for each

### Receipts list
1. The `⚠` floats in the row corner and says nothing (`ReceiptListScreen.swift:310`). **Change:** an inline warning line
   with the first review reason, so triage needs no tap.
2. Confirming a clean receipt takes a push and a button. **Change:** swipe right on a row for `Looks good`, next to the
   existing swipe left for `Delete`.
3. Swipe delete and item delete have no way back. **Change:** an `Undo` snackbar, because production does them without
   confirmation.
4. Filters are a nested menu: icon, submenu, value, with no sign of what is active afterwards. **Change:** one panel with
   date and store chips and a live result count, plus removable chips above the list while filtering. Also solves the
   `listFilters` launch state. This is a sheet, the app's only one.
5. Empty and no-match states are a single grey line (`:135`). **Change:** icon, text and the action itself (`Scan receipt`,
   `Choose photos`, `Clear filters`).
6. The upload progress bar is pen red (`UploadQueueView.swift:27`), the colour that means failure. **Change:** ink, with red
   for a failed row only. Tiny 11pt action links become real buttons.
7. Sync row, `Restore` and `Delete`, and the upload `xmark` are far below 44pt. **Change:** all 44pt targets.
8. The search field hides until pulled down. **Change:** always visible.
9. The Receipts tab gives no signal from elsewhere. **Change:** a tab badge with the review count.

### Receipt detail
10. Every item is a full form with name, fields, translation, three pickers and Save, about 300pt each, so reviewing nine
    items is a long scroll past pickers. **Change:** items are a compact summary row (name, translation, `qty × price`,
    category path, total) and expand to the same inline editor on tap. Flagged items start open. This is the biggest
    speed gain in the app.
11. The round `xmark` top right reads as "close" but deletes (`ReceiptDetailView.swift:164`). **Change:** a trash icon, same
    dialog.
12. The action button gives no idea what comes next. **Change:** a full-width `Looks good` with a line above it,
    `3 more to review · next: ALDI SÜD`.
13. A sum mismatch is only in the warning box at the top. **Change:** a red `Difference` line in the footer, where the
    printed total gets corrected.
14. `Looks good` is active on a receipt that is still being read. **Change:** disabled until extraction is out of the way.
15. The panel says `saved on this Mac` on an iPhone (`CloudSyncViews.swift:85`). **Change:** `this iPhone`, the one wording
    change, because the original is simply wrong here.
16. Bare `Set date` and `+ Add time` links, and the compact system picker shows `30. Oct 2026` or `29.10.26` depending on
    its space, while the rest of the app says `2026-10-30`. **Change:** outlined buttons, and mono pills in the app's own
    format that open the system picker in a popover.

### Overview
17. `Total:` is mono 22 and competes with the rest. **Change:** a hero number with the delta next to it, using the data the
    tree already has.
18. `‹ ›` are 30pt text glyphs. **Change:** SF Symbols, 44pt targets, `›` disabled on the current month.
19. Tree rows squeeze label, delta and amount on one line. **Change:** two lines, name and amount on top, delta beneath,
    rotating chevron, level by indent and weight.
20. Purchase `Edit` does nothing visible on iOS (noted in screens.md). **Change:** opens the receipt with the item open.

### Settings
21. Status is plain text with the same weight as everything else. **Change:** `Not sent yet` and `Refused by the server`
    get count pills; result lines get a tinted box.

### Palette, both modes
22. White on dark-mode pen red fails contrast, as do small `inkSoft` labels on `desk`. **Change:** same hues with
    `onRed` dark text in dark mode, a `label` tone for text on desk, and a dark-mode chart palette lifted for contrast.
