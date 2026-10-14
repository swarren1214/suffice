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
  accounts opens to In budget / Hidden switches.
- **Activity**: a segmented New / All switch. New (anything that arrived on its own or has no
  category) has a red badge with the count.
  Rows have the merchant avatar with the person's badge, date and account, and a red or green
  amount pill. Filter by spending, income or person; **+** adds a transaction.
- **Transaction sheet**: merchant, big amount, date · who · account, the category pill that
  opens into the list, the subcategory, "Always use this category for …", and the map when a
  transaction has a place. The same sheet adds new ones.
- **Budget**: what's left this month at the top right, then each budget as a tile in a
  two-column grid: its ring and icon, name, what's left (green, or red when over) and spent of
  planned. Tapping a tile opens the budget sheet; **+** opens a new one.
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
- The app icon is `Suffice/AppIcon.icon` from Icon Composer; the logo in the month
  button is still the WeBudget mark.

## Data model

All money is whole cents (`Int`), so sums never drift. Records link by UUID
(`categoryID`, `memberID`, `accountID`, `billID`, `parentID`) rather than SwiftData relationships: deleting a category
or a person never deletes history, and CloudKit has no required relationships to enforce.

- `BudgetCategory`: name, icon, color, monthly amount, parent (for subcategories), start
  month, repeats, order, archived.
- `LedgerEntry`: date, payee, amount, expense or income, category, member, account, note,
  bill, reviewed, place.
- `Bill`: name, amount, schedule (frequency, interval, first due date, optional end date, due
  day), color, category, autopay, subscription. Payments are `LedgerEntry`s with `billID` and
  the `billDueDate` they pay.
- `Account`: bank, name, last four, type, source (manual, Plaid, Wallet), balance and its
  date, in budget.
- `PayeeRule`: "always use this category" for a payee.
- `Member`: name, color, and an optional profile photo. Photos are cropped to a 400 px
  square JPEG (`MemberPhoto`) and stored with `@Attribute(.externalStorage)`, which CloudKit
  syncs as an asset. Pick one by tapping a person's circle in Who's budgeting? or in
  Profile › My info / Household; it shows on their transaction badges, the toolbar avatar
  and Profile.

Every property has a default and nothing is unique, so all six sync with CloudKit as-is.

## Turning on iCloud sync

The budget is saved on the device while `AppConfig.cloudSyncEnabled` is `false`. To sync
through the user's private iCloud database:

1. In **Signing & Capabilities**, confirm the iCloud container is checked under **CloudKit**.
   Push Notifications and Remote notifications are already in the entitlements and Info.plist.
2. Set `AppConfig.cloudSyncEnabled = true` and run once on a device signed in to iCloud.
3. In the CloudKit Console, deploy the development schema to production before TestFlight.

## Sharing with your spouse (next milestone)

Private-database sync keeps one person's iPhone, iPad and Mac in step. Two people on two
Apple Accounts need **CloudKit sharing**: one of you owns the budget and shares it, the other
accepts, and both read and write the same records. SwiftData's CloudKit integration doesn't do
sharing on its own, so the plan is:

- Keep the SwiftData models as they are for the UI.
- Add a small sync layer on `CKSyncEngine` that mirrors the four record types into a shared
  record zone, with a `UICloudSharingController` invite in Settings › Household.
- Until then, the simplest way for both of you to use it is one shared Apple Account for
  Suffice, or one person entering everything.

No server either way: shared zones live in the owner's iCloud.

## Next up

- CloudKit sharing for the household (above).
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
Lifestyle API (`Services/LifestyleAPI.swift`, base URL and keys in `AppConfig`). Sign in with
Apple (onboarding, or the first time someone taps Connect a Bank) replaces it with a durable
Supabase identity; banking refuses anonymous sessions.

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
