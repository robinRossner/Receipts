# Design 3 scout: neobrutalism

## What identifies the style
- High contrast, blocky layouts, bold flat colour, thick borders, deliberately "unpolished", 90s graphic nostalgia.
  More orderly and colourful than true brutalism (NN/g).
- Solid single-colour offset shadows with zero blur, about 4px; no gradients (NN/g). BoldKit codifies it as
  `3px solid` borders, `4px 4px 0` shadows, radius 0 ("keep it square"), bold uppercase for emphasis.
- Two or three strong colours, not a rainbow. Bright pairs can fail contrast, so check them (NN/g).
- Chunky display type paired with a neutral body face; headlines about twice body size (NN/g).
- Pitfalls to design against: elements that stop looking tappable, too many competing shapes, too little whitespace
  around heavy borders (NN/g).
- Press state (from the common CSS pattern in these libraries, not stated on the pages I could read): the element moves
  by the shadow offset and the shadow collapses, so it physically "goes in".
- Dark mode: none of the sources I read explains how, only that libraries support it. The decisions below are mine.

## Decisions
**Dark mode is its own palette.** Black borders vanish on a dark page, and inverting gives a muddy result. So: near-black
aubergine page, cream outlines, and a saturated violet hard shadow in place of black. Accent blocks stay full strength
with black text. Header slabs change to deep saturated colours, so the system's white status bar stays readable; in light
mode they are bright, and the system's black status bar reads on them. The colour scheme is never forced.

**Three colours, one job each.** Yellow = primary action and focus. Pink = needs attention. Blue = info and structure.
Green and red are reserved for OK and destructive. Text on any accent block is always black.

**Type.** Display: SF Pro Black Expanded, uppercase, for titles only. Body: SF Pro semibold/heavy, for legibility. All
numbers: SF Mono Bold, which echoes a till slip and keeps amounts aligned. German store names keep their own casing.

## Palette

| Token | Light | Dark |
| --- | --- | --- |
| page | #FFF6DC | #14121C |
| card | #FFFFFF | #231F31 |
| line (borders, rules) | #0B0B0B | #F4EEDC |
| shadow | #0B0B0B | #7B61FF |
| text / text2 | #0B0B0B / #3D3A33 | #F7F2E4 / #C4BFD2 |
| yellow | #FFD500 | #FFD60A |
| pink | #FF6FB5 | #FF7AC0 |
| blue | #5B8CFF | #7FA6FF |
| green | #2EE59D | #3CF0A8 |
| redFill (white text) | #E0102C | #C70F2A |
| redText | #C20A24 | #FF8A96 |
| flagFill | #FFF0A8 | #3D3510 |
| hero Receipts / Overview / Settings | #FFD500 / #FF6FB5 / #5B8CFF | #3A2BD6 / #B3126A / #0A6E62 |
| heroInk | #0B0B0B | #FFFFFF |

## Components (all custom, no stock chrome)
- **Slab**: square corners, 3pt border, 5pt hard shadow (small controls 2.5pt / 3pt).
- **Press**: moves by the shadow offset, shadow collapses to 0, no fade.
- **Tab bar**: full-width bar of three flush blocks, 4pt top rule. The selected block takes that tab's hero colour.
- **Header**: full-bleed hero slab under the status bar, 4pt bottom rule, icon blocks 44pt.
- **Segmented control**: flush bordered cells; the selected one is yellow with a heavy label.
- **Fields**: 3pt border, 48pt high, turn yellow-tinted when focused. Pickers: bordered block with a chevron, system menu.
- **Sticker**: small slab rotated 2 to 4 degrees, overhanging its parent (`⚠`, `4 to review`, `2×`).
- **Dialogs**: custom slab replacing every alert and confirmation dialog, tilted a degree, title bar pink for destructive
  and yellow otherwise, buttons stacked and at least 50pt.
- **Spinner**: a rotating bordered square.
- **Swipe to delete**: custom pan revealing a red block with the `Delete` label.
- **Charts**: hand-built bars with outlined segments; price history in Swift Charts with thick lines and square points.

## Screen spec
- **List**: hero with filter, title, scan, photos, then search. Sync row. Section labels as colour tags. Row: card with a
  10pt red left slab when unreviewed, `⚠` sticker on the corner, mono total. Filter panel drops from the header.
- **Uploads**: blue header strip, action buttons, segmented block progress bar, rows capped at 180pt.
- **Detail**: hero with back block and inline title; Items/Photo segmented; one scrolling card with heavy rules; fixed
  action bar with a big green `Looks good` and a `…` block that opens a custom menu.
- **Items**: flagged rows take flagFill; repeats share a heavy bracket with a `2×` sticker.
- **Overview**: range segmented, period row, tilted yellow total slab, chart cards with tag labels, tree with heavy rows;
  dashed box for price history.
- **Settings**: card per section with an overhanging tag label, footers under the cards, red destructive buttons.

## Sources
- [NN/g: Neobrutalism](https://www.nngroup.com/articles/neobrutalism/)
- [BoldKit](https://github.com/ANIBIT14/boldkit)
- [neobrutalism components (ekmas)](https://github.com/ekmas/neobrutalism-components), page read but gave no specifics

# Iteration 2: toned-down neobrutalism

Feedback: the yellow is a bit much on Receipts, tone the contrast and the "ummff" down, dark mode does not look
nice, items should fold. This section supersedes the palette, type and weight above. Retune in one place:
`BP` (colour pairs) and `BT` (borders, rules, shadows, tilts, scrim) in `BrutalTheme.swift`, `BF` for type.

**What stays neobrutalist:** solid outlines, zero-blur offset shadows, flat colour blocks, square corners, stickers,
the press-collapse behaviour.

**Scout:** no source defines "soft neobrutalism" as a named style. The closest evidence is that themes treat it as dials
([Brutato](https://www.obsidianstats.com/themes/brutato): border 1 to 4px, shadow offset 0 to 10px), cream or beige
instead of white ([The Plus Addons](https://theplusaddons.com/blog/neo-brutalism-web-design/)), desaturated accents and
off-white text in dark mode. The values below are my judgement.

## Decisions
- **Colour is an accent, not a wall.** Every header is the same quiet paper. Each tab keeps one signature colour on a
  tilted title block, its selected tab and its segmented control.
- **A shadow means something.** Receipts that need review have one, reviewed ones are flat. Elsewhere only the main action,
  the Overview total, title blocks, menus and dialogs have one.
- **Destructive is quiet until confirmed.** Red text on outline, filled red only inside a dialog.
- **Labels in sentence case** (`Needs review`, `Spending by month`, `Uploads - 3 of 5`): an explicit change from
  screens.md's capitals, to reduce shouting.
- **Dark mode rebuilt:** warm charcoal, mid warm-grey outlines (3.2:1 against card, enough for a non-text boundary), and a
  near-black hard shadow that does not glow. Same structure as light, so it reads as the same design.
- **Items fold.** Summary row: chevron block, name, translation · category, total, `qty × price`. Flagged items start open.

## Palette (light / dark)
| Token | Light | Dark |
| --- | --- | --- |
| page / card / header | #F3EEE4 / #FBF8F1 / #F9F5EC | #23211E / #2E2B27 / #2A2724 |
| line / shadow | #2C2925 / #2C2925 | #7D776D / #100F0D |
| text / text2 | #2C2925 / #5F594F | #EBE6DB / #B5AEA1 |
| butter / rose / blue / sage | #E7CF85 / #E2AAB2 / #A6BAD6 / #AECDAE | #C9B26E / #C4929B / #8FA3BE / #94B496 |
| redFill / redText | #B0463F / #A33B35 | #9E443D / #E39A91 |
| flagFill | #F6EBC9 | #3B3526 |

Measured text contrast is at least 4.8:1 for every text pair checked, in both modes.

## Weight and type
Borders 1.75pt (controls 1.25pt, dialogs 2pt, was 3 to 4). Shadows 2 to 3pt (dialogs 5pt, was 3 to 8). Tilts only on the
title block (-1°), stickers (2°) and the Overview total (-0.7°). Titles are SF Pro Heavy, slightly widened, mixed case at
21pt instead of Black Expanded capitals at 27pt. Body is regular or medium, numbers SF Mono semibold. The tab bar has no
cell dividers and shows one outlined selected block.
