# Suffice on iPhone Duo

Overnight pass (Oct 22, 2026), built on the shared layer in `Suffice/Services/Hearth/HearthDuo.swift`.
Nothing was compiled; everything passed the tree-sitter syntax check. Review with `git diff` plus the
three new files below.

## What changed

New files
- `Suffice/Models/SpendPace.swift`: pure math. Safe to spend today and this week (what's left of the
  month's plan spread evenly over the days left), spending per day, the week's days, the budgets
  closest to their limit, and `LimitLevel` (fine / near from 85% / over).
- `Suffice/Features/Budget/BudgetDuoViews.swift`: the Budget pose layouts. `SpendCheckView` (Closed),
  `CategoryLedgerSplit` (Open wide), `MoneyDateView` and `AgendaItem` (Book), `TodayBoard` (Tent), plus
  `LimitBarRow`, `LedgerLine`, `AccountLabel` (cards as last four digits) and `duoGreenChrome`.

Changed files
- `App/SufficeApp.swift`: `.hearthDuoPose()` on the scene root (`AppRoot`).
- `DesignSystem/Toolbar.swift`: `tabToolbar(isShown:)`, so a screen can leave the standard bar out.
- `Features/Budget/BudgetView.swift`: picks the layout from the pose; Add Expense, Filter and
  Today's Number toolbar items; Money Date agenda and its actions; budget grid now even-column.
  `BudgetSummaryCard` is no longer private (the Money Date reuses it).
- `Features/Bills/BillsView.swift`: Bill night in Laptop (this month only).
- `Features/NetWorth/DebtsView.swift`: loan grid now even-column.
- `Features/Ask/AskView.swift`: spoken-replies and Clear are titled Labels with symbols, grouped.
- `Features/Bills/BillSheet.swift`: Edit has a pencil symbol.
- `Features/Budget/BudgetSheet.swift`: removed the manual `ToolbarSpacer` (Duo rule: no manual spacers).

## How each pose behaves

- **Standard / Open tall** (inner portrait, other iPhones, iPad): Budget is unchanged, apart from the
  grid using 2, 4 or 6 columns. The color header keeps its iPhone fade; the tab bar stays at the bottom.
  New toolbar item: Today's Number (this month only).
- **Closed (outer display)** — Budget: "Can I spend this?" Safe to spend this week, then the three
  budgets closest to their plan, each with a bar (green, amber near the limit, orange over). Tap one
  for its budget sheet. Add Expense is the only toolbar item. Today's Number is a button in the
  content, so the rail keeps one item.
- **Open wide (inner landscape)** — Budget: budgets on the leading pane with Left to spend, Edit Budget
  and + above the list; the chosen budget's transactions on the trailing pane, with who paid and the
  account (cards as "Chase •••• 0293"). Add Expense and Filter (everyone or one person) are on the
  rail. Tapping a transaction opens it.
- **Book** — Budget: Money Date. Left page: the month's summary card, money in, and every budget's
  bar. Right page: an agenda from real data: budgets over plan (Open Budget), subscriptions and
  yearly bills due in 30 days and unpaid (Open Bill), stashes behind this month (Mark Stashed, which
  really counts it), and the top stash suggestion (Start a Stash). Each item shows as Settled once
  acted on.
- **Laptop** — Bills: Bill night. Upright half: the current bill, its statement amount, View Statement
  and Bill Details, and its last six amounts in six even columns. Flat half: the week's unpaid bills
  (late first) and Mark Paid, which pays it (same logic as the Bills list) and moves to the next.
  Budget in Laptop shows the standard screen.
- **Tent** — Today's Number, from the toolbar: what's safe to spend today in huge type, the week's
  spending as seven bars (today solid white, the rest faint), and Add Expense on the rail. Keeps the
  screen awake; Close dismisses it. Always this month.

State follows the hand: the chosen budget, settled agenda items, the ledger filter and the Bill night
position live in `BudgetView` / `MonthBudget` / `MonthBills`, above the pose layouts.

## Testing in the iPhone Duo simulator

1. Budget tab, phone open in portrait: the usual screen. Rotate to landscape: categories beside the
   ledger. Pick budgets; change Filter; open a transaction.
2. Close the device (outer display): safe-to-spend and three bars; Add Expense alone on the rail.
   Push a budget past 85% and past 100% to see amber and orange.
3. Fold to Book on the Budget tab: Money Date. Try each agenda action. Unfold and fold again; the
   settled items stay settled.
4. Bills tab, fold to Laptop: Bill night. Mark Paid a few; it advances. Unfold; Bills is back to normal,
   and the paid bills show ✓ Paid.
5. Budget toolbar › Today's Number (on the outer display, from the button in the content). Add an
   expense from the rail and watch the number and today's bar change.
6. Check iOS 26 on a regular iPhone: everything should look as before, plus the Today's Number item.

## Skipped, and why

- Live Activity / widget for Today's Number: a new target; out of scope.
- Two-level screens (Debts › Loan, Net Worth › Debts) still push on iPad. They live in a GreenScreen
  scroll view; a split would mean restructuring navigation.
- `ColorChoiceGrid` (5 columns) and the month picker grid (3) stay odd: they're inside sheets and
  popovers, not full-width grids a fold would split.
- `Services/Ask/AskSupport.swift` reads `userInterfaceIdiom`, but only to say "iPad" or "iPhone" in
  text, not for layout. Left alone.
- Custom bars kept on purpose: the Ask composer (chat input), onboarding's pinned buttons, the
  Overview card carousel.
- The Tax Year year picker and the month capsule are custom toolbar views (text with a chevron), so
  they won't show on the rail; they're menus by design (right-side checkmarks).
- The outer display's "same categories sit beside their ledgers when you open the phone": opening
  goes to Open tall (the standard screen). Only Open wide shows the ledger beside the budgets. The
  budget tapped on the outer display is remembered as Open wide's selection.

## Decisions to confirm

- Safe to spend = what's left of the plan ÷ days left in the month (today included), measured from
  this morning. "This week" runs to the end of the calendar week (or the month, if sooner). Fine?
- "Near the limit" starts at 85%. Amber is #F2A900, orange is the orange preset (#F3754D).
- Today's Number is also in the inner display's toolbar (Open tall, Open wide), not only on the
  outer display. Keep it there, or outer-only?
- Money Date's agenda: renewals are subscriptions and yearly bills due within 30 days. Settled items
  are remembered only while the screen stays open (not saved). Should they persist per month?
- Bill night only appears for this month, and only on Bills (not Budget).
- The Open wide Filter is by person (who paid). There's no account filter.

## Review (overnight)

A second pass acted as the compiler and design reviewer. Nothing was compiled.

What was checked
- Every new symbol against the codebase: names, argument labels, memberwise init order, access
  levels (BudgetSummaryCard is now internal; BillDue and the Bill night types stay file-private),
  @ViewBuilder and ToolbarContentBuilder use, duplicate type names (none). No banned API is used.
- The spots the author flagged: BillsView's six history slots and the Group/if/else braces in
  MonthBills.body; the trailing closure on SpendCheckView, which binds to `open` because
  `showTodayBoard:` is passed with its label; `case .startStash(let bill, due: let due)`, which
  matches the enum; HearthGlanceBoard with one ToolbarItem; symbolEffect inside a Label icon;
  `if` inside the toolbar builders. All fine.
- SpendPace: days left counts today and is at least 1, so there's no division by zero on the
  last day. A month over plan gives 0, never a negative number. Safe to spend never exceeds
  what's left.
- Mark Paid calls the Bills list's own `togglePaid` (Ledger.pay). Mark Stashed calls
  `StashScheduler.markStashed`. Both save through the model context, so household sync picks
  them up as usual.
- Colors: amber (#F2A900) and orange (#F3754D) only fill progress bars, never text. Over-plan
  text uses Brand.expenseInk.

What was fixed
- BudgetView.swift:282: Mark Stashed now shows only for stashes counted by hand, as in the
  stash sheet. On an automatic stash it could have recorded this month and made the scheduler
  skip months it still owed.
- BudgetDuoViews.swift:48: the account label uses the last four digits of the mask, even if a
  longer mask was stored.
- BudgetDuoViews.swift:344: the overspent agenda tile uses the orange ink, not the light
  orange, so its white glyph is legible.
- BudgetSheet.swift:156: put back the ToolbarSpacer between Edit and Done. Removing it merged
  the plain Edit button and the filled Done button into one glass group on every iPhone and iPad.

Remaining risks and open questions
- Bill night: for a variable bill without a statement, Mark Paid opens the payment sheet (as in
  the list) but still moves on to the next bill. The skipped bill stays in the queue.
- Money Date: an item shows as Settled as soon as its button is tapped, even if the sheet it
  opens (Open Budget, Open Bill, Start a Stash) is cancelled.
- BudgetSheet's spacer: keep it (the current look), or drop it for the Duo "no manual spacers"
  rule? Steve should decide.
- `.refreshable` sits on the pose Group, so in Open wide and Book both panes' scroll views can
  pull to refresh. This is harmless.
