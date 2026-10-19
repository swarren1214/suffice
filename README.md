# Suffice

A native iPhone budget for a household: total cash across your accounts, every transaction
with who made it, budgets with subcategories, and the bills. SwiftUI with Liquid Glass,
SwiftData for the ledger, the household's own iCloud as the only backend. No accounts and no
servers.

The screens follow the **MVP v2** designs on the "WeBudget iOS" Claude Design canvas (Welcome,
Connect accounts, Overview, Activity, Transaction detail, Budget, New budget, Bills, Profile):
the green gradient header with a white large title, the glass month capsule and glass
action + avatar group in the toolbar, white 26 pt cards, red and green amount pills, merchant
avatars with who-badges, budget rings, and the Liquid Glass tab bar with the separate search
button. Suffice is the third app in the family with Sated and Hearken.

Requires Xcode 26 and iOS 26. iPhone only.

## First run

1. Open `Suffice.xcodeproj`.
2. Select the **Suffice** target › **Signing & Capabilities** and confirm your **Team**
   (the same team as Sated and Hearken). Automatic signing registers Sign in with Apple and
   iCloud the first time you build.
3. If `com.stephenwarren.suffice` isn't available to your team, change the **Bundle
   Identifier**, then update the iCloud container in `Suffice.entitlements` and
   `AppConfig.cloudKitContainerID` to match.
4. Run. Onboarding is Welcome → Connect accounts → Who's budgeting. Signing in with Apple is
   optional (it only fills in your name), so nothing is held behind a login. Previews load the
   household from the designs (`App/PreviewSupport.swift`).

The first launch adds the budgets from the designs with no amounts: Home (Mortgage, Home
improvements), Auto (Gas, Insurance), Food (Groceries, Fast food), Utilities (Power, Gas),
Entertainment (Streaming, Date night) and Giving.

## Screens

- **Overview**: the Liquid Glass Total cash card (checking, savings and cash that are in the budget)
  with this month's income and expenses, then accounts grouped by bank. A bank with several
  accounts opens to In budget / Hidden switches. Under the cards: the Net worth card, the
  accounts, and Loans.
- **Net Worth** (Overview › Net worth): everything owned minus everything owed in the glass
  card, how it moved since last month, a month-by-month trend (6M / 1Y / All), then Assets
  (every account, in the budget or not, plus homes, cars and investments typed in by hand) and
  Debts (loans with their paid-off rings, credit cards with what's owed).
- **Emergency Fund** (Net Worth › Emergency fund): months of essentials the household could
  cover from savings if both paychecks stopped, a gauge with the goal marked, saved and
  essentials a month. Below: the goal (1–12 months) and what closing the gap in a year takes,
  with Stash to start a stash for it; which accounts count (savings on to begin with); and
  which budgets are essential (Home, Utilities, Auto and Groceries to begin with), plus loan
  payments and yearly stashes at their cost ÷ 12.
- **Debts** (Net Worth › See all, Overview › Loans › All Debts): what's left on every loan and
  when the last is paid off, each loan as a tile with its ring, a payoff timeline, and a tip
  when rolling a finished loan's payment into the biggest one saves a year or more.
- **Loan** (tap a loan): balance and share paid off, the facts (borrowed, term, time left,
  interest paid and still ahead, escrow, the saved plan), how the next payment splits between
  principal and interest, each year's payments as a stacked chart, and the amortization
  schedule by year or by month. Edit opens the loan editor.
- **Payoff Plan** (a loan › Plan a Payoff): pick any loan, then try extra each month, a
  one-time payment, a refinance rate and biweekly payments. Shows the new payoff date, time and
  interest saved, the balance over time against the schedule, and a side-by-side comparison.
  Save as My Plan keeps the extra on the loan (its projections use it); Add Extra Payment to
  Bills adds a monthly bill for it.
- **Activity**: a segmented New / All switch. New (anything that arrived on its own or has no
  category) has a red badge with the count.
  Rows have the merchant avatar with the person's badge, date and account, and a red or green
  amount pill. Filter by spending, income or person; **+** adds a transaction.
- **Transaction sheet**: merchant, big amount, date · who · account, the category pill that
  opens into the list, the subcategory, "Always use this category for …", and the map when a
  transaction has a place. The same sheet adds new ones.
- **Split** (transaction › Split Across Budgets, or Split From This Receipt): one charge across
  budgets. Parts each have a budget or subcategory and an amount; Done is enabled once they add
  up to the charge. The first part is "the rest" until its amount is typed, so splitting off one
  thing is a budget and an amount; Split Evenly and Rest to Last Part help. With a receipt, the
  on-device model reads the items and suggests the parts (`Services/ReceiptSplitter.swift`:
  Vision reads the text, the model sorts items into budgets, prices are scaled to the charge so
  tax spreads by size). A split charge stays one row in Activity ("Split · Food, Home"); each
  budget counts only its part and lists it as "Part of a $214.37 split". Removing parts down to
  one undoes the split.
- **Budget**: what's left this month at the top right, then each budget as a tile in a
  two-column grid: its ring and icon, name, what's left (green, or red when over) and spent of
  planned. Tapping a tile opens the budget sheet; **+** opens a new one. Left to spend is
  planned, less what went to stashes this month, less spent (the Stashed tile).
- **Stashes** (Budget › Stashes, this month): money set aside month by month for costs that
  come once or twice a year. Each has a ring, what's stashed of its target and its date, the
  monthly amount and On track / Behind / Fully stashed. A card suggests one for a bill that
  comes every three months or less often with two or more 1sts to go; Not Now remembers it.
  The stash sheet shows the amount each month with a bar per month, then the amount, due date,
  Every year / Just once, what's already stashed, the account it's kept in, and Count it on
  the 1st (off: Mark Stashed each month). Bills › a bill › Stash for This opens one for it; a
  bill with a stash shows "Saving $48/mo". When the bill is paid (Mark Paid or matched from the
  bank) it's paid from the stash, so it doesn't count against that month's budget; a yearly
  stash then starts over for next year. Other spending can be paid from a stash with the
  transaction's Paid From row.
- **Tax tags** (transaction › Tax): a tag on spending (charitable giving, medical, HSA or FSA
  eligible, childcare, education, business). Tags never change budgets. The Tax row opens into
  the tags like the category list; "Always tag ‹payee› as ‹tag›" makes a payee rule and offers
  to tag this year's earlier ones; a tagged transaction without a receipt shows Keep the
  Receipt with Scan. A split's parts can carry their own tags, and a budget can have one
  (budget sheet › Tax Tag). A new transaction gets its own tag, else its payee rule's, else its
  budget's, stamped when it's saved or arrives from the bank.
- **Tax Year** (Profile › Tax Year): a year of tagged spending: the total with a bar by tag and
  how many have receipts, the ones without a receipt, each tag's total and transactions,
  mortgage and student loan interest from the loans' schedules (an estimate; the lender's Form
  1098 is the official figure), the rules, and Share With Your Tax Preparer: a PDF summary, a
  spreadsheet of every tagged transaction or split part, and the receipts as JPEGs.
- **Budget sheet**: the big ring, the name (editable in place), what's left, and spent of
  planned with the days to go. Below it the budget's settings: monthly amount, Every month /
  One month only with its start month, "Part of" for making it a subcategory, color, and
  icon. Then Subcategories: the amount set first, then split across them with a bar and
  legend, each with its amount in the row (tap to rename, change its icon or delete), and
  "Rest of …" for what isn't assigned, which covers spending filed to the budget itself.
  Assigning it all isn't required; going over shows a warning with "Raise … to $x". Then
  this month's transactions. Done saves; the X discards.
- **Bills**: due in the next 7 days with the week strip, Upcoming with Mark paid / ✓ Paid,
  Subscriptions, and the bills not due this month with their next date. Bills repeat once, or
  every N weeks, months or years from a first due date, and can end on a date. Mark paid records
  the payment in Activity under the bill's category for that one due date (tap again to undo);
  long-press for Pay a Different Amount. Unpaid dues from earlier months stay listed as overdue.
- **Search** (the round button): every transaction, any month.
- **Ask Suffice** (✨ at the top of every tab, or ⌘K): questions about the household's money,
  answered on the device. See "Ask Suffice" below.
- **Profile** (the avatar): My info, Household, Connected accounts, Ask Suffice (voice settings),
  About (with CSV export), Lock with Face ID, Erase Suffice data.

### Where the build goes beyond the designs

- **Adding transactions by hand.** The designs assume bank sync, which isn't connected yet, so
  Activity has a **+** next to Filter, and the transaction sheet gains Type, Who, Account,
  Date and Note rows when you're adding one.
- **Connect a bank** runs Plaid (see Bank sync below) once the relay is deployed and LinkKit is
  in the build; until then it says so and offers to add the account by hand. **Add from Apple
  Wallet** waits on Apple approving FinanceKit. Manual balances move with the transactions
  filed to them.
- **Onboarding** follows Hearken's sign-in screen rather than the MVP v2 Welcome and Connect
  designs. All three steps (sign in, connect accounts, who's budgeting) share one layout in
  `Features/Onboarding/OnboardingPage.swift`: icon, large title, one-line promise, content,
  and buttons pinned to the bottom. Step 1 shows the app icon from Icon Composer's light and
  dark PNG exports (`SufficeMark` in the asset catalog; re-export them if the icon changes);
  steps 2 and 3 use an SF Symbol on the same green rounded square, with step dots above.
  Signing in is optional, after Hearken's App Review rejection over sign-in. Step 3 wasn't in
  the designs; it asks for your name and your partner's. The lock screen uses the same layout.
- **Names from Caloma:** when Caloma is on the iPhone and has shared its family, Who's
  budgeting? offers "Use names from Caloma?" (its parents) while the partner's name is empty and
  yours is empty or one of them; × hides it for good. Profile › Household offers "Add … from
  Caloma" if no one's been added yet. Both bring Caloma's photo of each parent along. Read through the Hearth app group
  `group.com.stephenwarren.hearth` (`Services/CalomaFamily.swift`, `Services/Hearth/`; the app
  target only, and tick App Groups › that group under Signing & Capabilities). Off in screenshot
  mode.
- The app icon is `Suffice/AppIcon.icon` from Icon Composer; the logo in the month
  button is still the WeBudget mark.

## Data model

All money is whole cents (`Int`), so sums never drift. Records link by UUID
(`categoryID`, `memberID`, `accountID`, `billID`, `parentID`) rather than SwiftData relationships: deleting a category
or a person never deletes history, and CloudKit has no required relationships to enforce.

- `BudgetCategory`: name, icon, color, monthly amount, parent (for subcategories), start
  month, repeats, order, archived.
- `LedgerEntry`: date, payee, amount, expense or income, category, member, account, note,
  bill, reviewed, place, and `splitsJSON`: a split charge's parts (`EntrySplit`: budget and
  amount), two or more adding up to the amount, with `categoryID` set to the biggest part's.
  BudgetMath counts each part toward its own budget (`EntryRecord.parts`). When the bank changes
  a split charge's amount, the last part takes the difference and it goes back to New.
- `Bill`: name, amount, schedule (frequency, interval, first due date, optional end date, due
  day), color, category, autopay, subscription. Payments are `LedgerEntry`s with `billID` and
  the `billDueDate` they pay.
- `Account`: bank, name, last four, type, source (manual, Plaid, Wallet), balance and its
  date, in budget.
- `PayeeRule`: "always use this category" and "always tag as" for a payee (`taxTagRaw`).
- `Stash`: name, icon, color, target, due date, repeats yearly, what was already stashed, the
  account it's kept in, the bill it pays, counts on the 1st, essential, archived. Its balance is
  what it started with plus its `StashMove`s less what it paid for (`LedgerEntry.stashCents`).
- `StashMove`: one month's amount counted toward a stash. Two devices can both count the same
  1st; `SyncCleanup` keeps the oldest.
- New fields: `LedgerEntry.stashID`/`stashCents` (paid from a stash: that much doesn't count in
  the month's budget) and `taxTagRaw`; `EntrySplit.taxTag`; `BudgetCategory.isEssential` (nil
  until picked) and `taxTagRaw`; `Account.isEmergencyFund` (nil until picked). The runway goal,
  whether loan payments are essential and dismissed stash suggestions are in iCloud key-value
  storage (`PlanningSettings`).
- `Loan`: name, lender, type, color, amount borrowed, rate, term, first payment date, payment
  (principal and interest), escrow, the balance on a date, the saved extra, paid off. Today's
  balance is that balance less the scheduled payments due since (`LoanMath.currentBalance`);
  typing in a statement's balance starts the count again.
- `OwnedAsset`: a home, vehicle, investment or other, with its value and the date it was set.
- `NetWorthSnapshot`: one month's assets and debts, rewritten as this month's totals change,
  for the trend. Two devices may write one for the same month; the latest wins when read.
- `Member`: name, color, and an optional profile photo. Photos are cropped to a 400 px
  square JPEG (`MemberPhoto`) and stored with `@Attribute(.externalStorage)`, which CloudKit
  syncs as an asset. Pick one by tapping a person's circle in Who's budgeting? or in
  Profile › My info / Household; it shows on their transaction badges, the toolbar avatar
  and Profile.

Every property has a default and nothing is unique, so they all sync with CloudKit as-is.

Loan and net worth arithmetic is in `Models/LoanMath.swift` (pure functions, pinned by
`SufficeTests/LoanMathTests.swift`): interest is the balance times the monthly rate, rounded to
the cent; a calculated payment rounds up so the loan ends within its term; biweekly payments
count as a thirteenth payment a year spread across the twelve; a refinance keeps the time left.

Stashes, the emergency fund and tax tags have their own pure files: `Models/StashMath.swift`
(a stash's monthly amount is what's still needed over the 1sts left, due month included,
rounded up to the dollar), `Models/RunwayMath.swift` and `Models/TaxMath.swift`, pinned by
`StashMathTests`, `RunwayMathTests` and `TaxMathTests`. `Services/Planning/StashScheduler.swift`
counts the 1st on launch, on foreground and after household sync, and pays bills from stashes.

## iCloud sync and household sharing

The SwiftData store is local (`cloudKitDatabase: .none`). `HouseholdSync`
(Services/Household) carries it to iCloud with **CKSyncEngine**, because SwiftData's own
CloudKit sync can't share data with a second Apple Account.

- **Zone:** everything lives in a record zone named `Household`. The owner keeps it in their
  private database and shares the whole zone (`CKShare(recordZoneID:)`); a member who accepts
  sees it in their shared database. Both read and write it, and each person's own devices sync
  the same way.
- **Records:** one per model, named `<Type>.<uuid>` (`SyncRecords.swift`). Every field is in
  `encryptedValues`; member photos are assets.
- **Sending:** SwiftData history (each model's `id` is `.preserveValueOnDeletion`, so deletions
  say which record went) becomes pending changes on the engine. Changes applied from iCloud are
  saved under the author `household-sync` and skipped.
- **Conflicts:** last writer wins: on `serverRecordChanged` the server's version is kept and
  ours is saved on top.
- **Joining:** tapping an invitation (scene delegate → `HouseholdSync.receive`) asks first, then
  replaces the budget on that device with the household's. The member's own budget stays in
  their private iCloud and comes back when they leave or the owner stops sharing. A member's
  other devices switch over by themselves.
- **Erase App Data:** for a member it becomes Leave Household (erasing would delete the
  household for both of you).
- **Banks:** each person connects their own; a bank only syncs from the Apple ID that
  connected it, and its transactions reach everyone through the household.
- **Duplicates:** two devices that each seeded starter budgets, set up the household, or synced
  the same bank end up with doubles. `SyncCleanup.mergeDuplicates` folds them together at launch
  and after each download, always keeping the oldest copy so every device chooses alike.
- **Schema:** a Debug build run from Xcode saves one of every record type, with every field,
  into the CloudKit *development* environment once (then deletes it). TestFlight and the App
  Store use *production*: in the CloudKit Console, **Deploy Schema Changes** before uploading a
  build, and again after any model change.
- **Status:** Profile › iCloud Sync (pull to sync now); Profile › Household › Sharing.

## Next up

- Bank transactions through Plaid with a tiny serverless relay (Plaid requires the secret
  off-device), and Apple Card / Apple Cash through FinanceKit once Apple approves it. Imports
  land in Activity › New; payee rules file them.
- Location on new transactions (for the map), and receipts.
- Roll-over of unspent amounts, per-month amount changes.
- Widgets, App Intents ("I spent $40 at Costco") and bill reminders.
- A Suffice mark to replace the WeBudget logo.

## Project layout

```
Suffice/
  App/            App entry, router, tab bar, configuration, preview data
  DesignSystem/   Brand, category and member colors, header, cards, pills, rings, toolbar
  Features/       Onboarding (welcome, household, lock), Overview (accounts, connect),
                  NetWorth (net worth, debts, loan, payoff plan, loan and asset editors),
                  Activity (list, transaction sheet), Budget (tiles, budget sheet), Bills,
                  Search, Profile
  Models/         SwiftData models, budget math, persistence and starter budgets
  Services/       Ledger (transactions, rules, bills, CSV, erase), Face ID lock, Ask (the
                  on-device model and its tools), Voice (speech, Kokoro, spoken replies)
  Resources/      Kokoro voice styles (kokoro-voices.bin, ~14 MB)
Packages/         KokoroSwift and MisakiSwift (vendored, the same copies as Sated and Hearken)
SufficeTests/     Swift Testing
```

## Ask Suffice

The Ask sheet (`Features/Ask`) follows the Ask designs: a welcome card, "Right now" (budgets
at 80% or more, bills due this week), suggested questions, chat, and a voice screen.

- **The model**: Apple's on-device model (Foundation Models), as in Sated. It answers through
  six tools over the household's data (`Services/Ask/AskData.swift`): getBudgets, getBudget,
  getBills, getSpending, findTransactions and checkAffordability. Every figure comes from
  BudgetMath; the model only words the answer.
- **Cards**: the reply names a budget, asks for a spending breakdown, or proposes a move between
  budgets. The app draws those cards from the live data (budget ring with biggest payees and
  Open, bars by budget split by person, Move / Not now), so a wrong number from the model can't
  end up in a card. A move changes the two budgets' monthly amounts only when Move is tapped.
- **Voice**: the same hands-free conversation as Sated's Coach (`Services/Voice`): on-device
  speech recognition, Apple's voice processing (echo cancellation, so you can interrupt), and
  spoken replies with Kokoro. The Kokoro model (~330 MB) lives in the shared App Group
  `group.com.stephenwarren.voice`, so if Sated or Hearken already downloaded it, Suffice uses
  it; otherwise it downloads once from Profile › Ask Suffice or the voice screen. Until then,
  and in the Simulator, replies use the best Apple voice installed.
- **Devices**: needs a device with Apple Intelligence (iPhone 15 Pro or newer). Elsewhere the
  ✨ button is hidden and everything else works.

## Widgets

The SufficeWidgetsExtension target has three widgets, all reading one snapshot the app writes
into the app group `group.com.stephenwarren.suffice` (`Shared/WidgetSnapshot.swift`):

- **Left to Spend** (small, medium, large, and Lock Screen circular, rectangular and inline):
  what's left of this month's plan on the brand green, with each budget's icon and bar.
- **Upcoming Bills** (small, medium, large, Lock Screen rectangular and inline): late bills
  first, then what's coming up, with what's due in the next 7 days.
- **Total Cash** (small, Lock Screen rectangular): Overview's total with the month's in and out.

The app rewrites the snapshot after every save (debounced), on launch, and when it goes to the
background, and only reloads the widgets when something changed. Widgets never open the
SwiftData store, so they don't touch CloudKit. Timelines step through the next three midnights
so "Tomorrow" becomes "Today" on its own. Tapping opens `suffice://budget`, `suffice://bills`
or `suffice://overview`. Amounts are marked privacy-sensitive, so the Lock Screen hides them
while the iPhone is locked.

Both the app and the widget extension need the App Groups capability with
`group.com.stephenwarren.suffice`. `Shared/` (Theme, Formatting, WidgetSnapshot) builds into
both targets.

## Apple Watch

`SufficeWatch` (the watch app) and `SufficeWatchWidgetsExtension` (its complications) ship
inside the iPhone app; there's nothing separate to upload.

- **Data**: the iPhone sends the widget snapshot (`Shared/WidgetSnapshot.swift`) to the watch
  with WatchConnectivity whenever it changes (`Suffice/Services/WatchSync.swift`): as the
  application context, and as a complication update when a Suffice complication is on the face
  (spaced at least 10 minutes apart; iOS allows about 50 a day). The watch app saves it in the
  watch's own app group and reloads the complications. The watch never opens the budget.
- **Watch app**: three pages, swiped up and down: left to spend this month, every budget
  (tightest first), and bills due in the next two weeks.
- **Complications**:
  - *Left to Spend*: what's left of everything planned, a ring that empties from green to red
    (circular, corner, rectangular, inline).
  - *Budget*: one budget, chosen when editing the face (each budget is also offered as a
    ready-made suggestion); its icon, ring and dollars left.
  - *Up Next* (Smart Stack): bills due today in the morning, Dining Out at lunch and dinner,
    Groceries on weekend mornings, otherwise the budget closest to its amount. Each timeline
    entry carries its own relevance, so the Smart Stack raises it when it matters.

## iPad

The app and widgets run on iPad in every orientation, in Split View and Stage Manager.

- Tabs sit in a bar at the top that opens into a sidebar (`.sidebarAdaptable`), with names;
  the iPhone tab bar stays icons only.
- Every tab keeps its cards to an 820 pt column in the middle; the green header runs edge to
  edge. Budget tiles fill as many columns as fit.
- Keyboard: ⌘N new transaction, ⌘1–4 the tabs, ⌘F search, ⌘[ and ⌘] previous and next month,
  ⌘T this month.
- The Face ID cover hides every open window.
- Left to Spend and Upcoming Bills also come in the extra-large widget size.

## Shared API identity and bank sync

Suffice silently creates a Supabase anonymous session for non-banking calls to the shared
Hearth API (`Services/HearthAPI.swift`, base URL and keys in `AppConfig`). Sign in with
Apple (onboarding, or the first time someone taps Connect a Bank) replaces it with a durable
Supabase identity; banking refuses anonymous sessions.

**One sign-in for every Hearth app.** BigTable, Suffice and Sated use the same Supabase project,
so a signed-in session is shared through `HearthAccounts` (Keychain, access group
`group.com.stephenwarren.hearth`; see `HearthSharedSession` in `Services/Hearth/HearthShared.swift`).
Anonymous sessions are never shared. Suffice adopts the shared session when it has none or only
an anonymous one; publishes its own if it was signed in before sharing existed; re-reads the
shared one before spending a refresh token (another app may have refreshed already) and keeps
whichever token expires later; and saves the session and the Apple user (name and email, which
Apple only sends the first time) after signing in or refreshing. Erase App Data signs out of
every Hearth app on the device. When another app signs out or switches person, Suffice follows
on `Hearth.didChange` or when it becomes active (`HearthSignIn`), going back to anonymous and
clearing `SettingsKey.appleUserID`. A refresh token Supabase rejects is remembered (as a hash)
so the dead session isn't adopted again. Off in screenshot mode.

**People's photos.** `Services/HearthHousehold.swift` publishes the household as Suffice's
`HearthFamily` (everyone as an adult, badge ink color, `me` = This is me, photos as shared JPEGs)
after saves (debounced, like the widgets), on launch and when the app becomes active, then
removes photos it no longer uses. Anyone without a photo here shows the photo another Hearth
app has of someone with the same name (`HearthPhotos`, cached by name, cleared on
`Hearth.didChange`). Off in screenshot mode.

Banks connect through Plaid (`Services/BankSync/`, LinkKit 7 via Swift Package Manager):

- **Connect:** Apple sign-in if needed → `POST /v1/banking/link-token` → Plaid Link →
  `POST /v1/banking/connections` with the public token. The API exchanges it and keeps the
  access token, sealed, in Supabase; the app never sees it. The bank's accounts appear on
  Overview as Plaid accounts (balances from the bank), then the first sync runs. Each bank is a
  `LinkedBank` with its item ID and sync cursor.
- **Sync:** `POST /v1/banking/connections/{itemId}/sync` with the bank's cursor, page by page.
  New transactions land in Activity › New (categorized when a payee rule knows the merchant);
  bank edits update amount, date and payee but keep people's category, person and note;
  removals delete. `LedgerEntry.externalID` (Plaid's transaction ID) prevents duplicates.
  Pending transactions arrive once they post. Transactions are stored only on the device and in
  iCloud, never on the API.
- **When:** after connecting, on pull to refresh on Overview, and on opening the app when it's
  been an hour. Profile › Connected accounts lists banks with Sync, Sign In (when the bank
  needs it; Plaid update mode) and Disconnect. Erase App Data disconnects banks first.
- **Logos:** Plaid's merchant logo when there is one, otherwise Logo.dev by the merchant's
  domain straight from its CDN (`AppConfig.logoDevPublishableKey`, a publishable `pk_` key);
  initials otherwise.

Still to do: keeping transfers and card payments from counting as spending or income, OAuth
banks (needs `PLAID_REDIRECT_URI` on the API plus an Associated Domains universal link), and
letting a spouse sync banks the other person connected (only the connecting Apple ID can).

## Bills & Receipts

### Reading bills

- **Where bills come from.** A bill PDF or photo can be shared or opened into Suffice (Share › Suffice, or Files › Open In), scanned on the Bill sheet, or found in email. Suffice reads it on the device: PDFKit text, Vision for scans, and the FoundationModels `DocumentReading` schema (`Services/Documents/DocumentReader.swift`).
- **Where it's saved.** Each one becomes a `BillStatement` (synced, document as a CloudKit asset) on the matching bill: the amount, due date, period, and charges.
- **How it changes paying.** A variable bill with a statement within 10 days of its due date pays that amount (`StatementMath`), and the statement goes with the payment as its receipt. Bills shows "From your Oct bill · usually ~$150"; the Bill sheet shows the statement, its charges and a history chart.
- **Pay links.** A bill can keep a pay link (`Bill.payURL`, https only). Its Pay ↗ button opens the biller's own page. Suffice never moves money.

### Receipts from Email (Profile › Receipts from Email)

- **What it does.** Gmail and Outlook connect read-only (OAuth with PKCE in `ASWebAuthenticationSession`). Tokens are kept in this device's Keychain and never sync.
- **What gets read.** `ReceiptScanner` searches only for receipt, order and bill words, then reads up to 60 new messages per scan on the device. It runs on opening the app (at most every 6 hours, after bank sync) and on pull-to-refresh in Email Receipts.
- **Matching.** `ReceiptMatcher` matches each receipt against transactions:
  - Same amount, store and day is a **sure** match and attaches on its own (Settings: "Attach when it's sure").
  - Tips, two charges, dates a few days apart, or names that differ are **check** matches and wait for Attach or Not This One.
  - Receipts with no transaction wait 30 days.
- **Bills in email.** Bills found in email become statements ("Find bills too").
- **Where found receipts live.** `FoundReceipt` is local-only and not in `SyncRegistry`: it remembers which messages were read. The attached receipt itself syncs on the transaction (`receiptData`, `receiptSourceRaw = "email"`, `receiptLink`).

### Setting up the OAuth clients (needed before Connect turns on)

Fill in `AppConfig.googleClientID` and `AppConfig.microsoftClientID`. While either is empty, its Connect button stays off.

**Google**

1. In Google Cloud Console, create a project and enable the Gmail API.
2. Set up the OAuth consent screen and add the scope `https://www.googleapis.com/auth/gmail.readonly`.
3. Create an **iOS** OAuth client for bundle ID `com.stephenwarren.suffice` and copy its client ID.
4. Nothing goes in URL Types. The sign-in sheet catches the reversed client ID (`com.googleusercontent.apps.<id>`) itself.
5. Know the limits. `gmail.readonly` is a *restricted* scope: until Google verifies the app (including a yearly CASA security assessment), only test users you list can connect, up to 100 of them. That covers you and your wife.

**Microsoft**

1. In Entra ID › App registrations, register an app and allow "Accounts in any organizational directory and personal Microsoft accounts".
2. Add the **iOS/macOS** platform with bundle ID `com.stephenwarren.suffice`. Its redirect is `msauth.com.stephenwarren.suffice://auth`.
3. Add the delegated permissions `Mail.Read`, `User.Read` and `offline_access`.
4. Copy the Application (client) ID.

**CloudKit**

`BillStatement` is a new record type, and `LedgerEntry` (`receiptSourceRaw`, `receiptLink`) and `Bill` (`payURL`) have new fields. Run the schema seed (Profile › CloudKit (Debug)) on a development build, then deploy the schema to Production in the CloudKit Console before shipping.
