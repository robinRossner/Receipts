# Design 4: The Supermarket

Each tab is a different part of one German supermarket, with its own materials and type. The whimsy lives in materials
and short transitions. No action takes an extra tap, and data stays in plain high-contrast type.

## The places

| App part | Place | Material and type | Why it is unique |
| --- | --- | --- | --- |
| Tab bar | Conveyor belt | Black ribbed rubber in both modes; the selected tab is a "next customer" divider bar | The belt runs when you change tab |
| Receipts | Checkout (Kasse 1) | Beige till plastic, keycaps, green LED customer display; Menlo on thermal paper | Slips feed from the printer slot under the till |
| Needs review | Printer output | Slips with a torn zig-zag edge, the red end-of-roll stripe as the unreviewed edge, yellow `⚠` sticker | |
| Reviewed | Receipt spike | Tighter slips with a punched hole on a steel rod | Reads as filed |
| Recently deleted | Bottle return (Leergut) | Grey crate panel with a row of bottle holes | Things can come back, like a deposit |
| Filters | Shelf-tag rack | Steel rails holding tags; yellow is selected | |
| Detail | The full receipt | Long paper from a printer fixed at the top, barcode footer, printed lines that unfold | Paper scrolls out of the slot |
| `Looks good` | Rubber stamp | Green till key; a `REVIEWED` stamp lands with a haptic, then the next receipt | 0.45 s, none with Reduce Motion |
| Warnings | Hand-written note | Yellow taped note in Noteworthy | |
| Photo | Pegboard | Original held by a bulldog clip on a perforated board | |
| Overview | The aisles | Navy hanging signs, DIN Condensed; red-on-yellow discount sign for the total | Categories are numbered aisles |
| Charts | Shelves | Months stacked as crates on a shelf board; stores as shelf-edge bars with a price tag | |
| Price history | Coupon | Dashed cut-out with scissors | Production's dashed box, explained |
| Settings | Back office | Sage wall, clipboard with metal clip, American Typewriter | OPEN/CLOSED door sign is the connection state |
| Sync, test, photos | Time card, fuse lamp, stock shelf | Buff punch card, glowing lamp, fill gauge | |
| Dialogs | Till notices | Paper printed from a slot, keycap buttons | |
| Empty states | Blank paper stub, empty shelf, CLOSED sign | | One for each place |
| Loading | Barcode scan beam | Red beam over a barcode | |

## Palette (light / dark)

Dark is the store after closing: warm charcoal, with glowing LEDs and lit signs. Paper stays paper, slightly dimmed.

- Paper `#FBF9F2` / `#E6E1D4`, ink `#23201C` in both.
- Price-tag yellow `#FFD21F` / `#E9BE1A`, sale red `#B00C22`.
- LED green `#7CF29A` on `#14160F` in both modes.
- Checkout `#DEDBD3` / `#1C1A18`, till plastic `#CFCBC0` / `#2B2926`.
- Aisle floor `#ECEDEA` / `#1E1D1B`, sign navy `#1D3B5F` / `#223F60`.
- Office wall `#DCE1D6` / `#1D201B`, clipboard `#A47E55` / `#4D3C2B`.

Saturated colour appears only on small objects: tags, keys, one sign.

## Type

Menlo for anything printed, DIN Condensed Bold for signs, DIN Alternate Bold for shelf figures, American Typewriter for
office forms, Noteworthy Bold for hand-written notes. All are bundled with iOS.

## Motion

Belt ribs slide on tab change, a new slip feeds out of its row, item rows unfold with a snappy spring, the stamp presses
in, notices feed down, the scan beam loops. Reduce Motion removes all of these except instant state changes.

## Per screen

- **List:** the till is a fixed header (lane lamp, title, three keys, LED sync line, search). Rows use dotted leaders
  between store and total.
- **Processing:** the upload panel is a printer tray with an LED counter; processing rows have a mini scan beam in place
  of a spinner.
- **Detail:** fixed printer on top with Items/Photo keys, fixed key deck at the bottom. Date and time are printed text
  over an invisible system picker, so they stay in Menlo. Rows are collapsed one-liners, flagged rows start open.
- **Overview:** range tags on a rail, sign with month arrows, discount-sign total, shelf chart, store tags, aisle tree.
- **Settings:** door sign, then clipboard sections.

## Revision: calmer Receipts tab and tab bar

It was found that the Receipts tab and the belt too busy, so Receipts now has one idea: a tidy stack of paper receipts on a calm
counter. Removed: till body, lane lamp, LED panel, keycaps in the header, printer slot, spike, staggered rows, dotted
leaders in the list, Leergut panel, the conveyor belt. Needs review differs from reviewed by the red edge and a small
warning mark only. The tab bar is one flat surface with a single rule; the selected label sits on a small yellow tag. The
table above still describes Overview, Settings and the detail screen.

## Revision 2: one long receipt

The separate slips lost the receipt, so the Receipts tab is now one strip of thermal paper fed from a printer slot under
the title and search. Rows are printed lines with fine dashed rules, sections are printed headers, and the paper ends in a
summary line, barcode and torn edge. Dark mode uses a dimmed paper token for this list only.
