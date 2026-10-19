# AGENT.md — Suffice

Rules for anyone (person or agent) changing Suffice's code. See README.md for how the app is
built and what each screen does.

## Design for every device

Always make sure layouts and designs work well on every device type Suffice runs on: every
iPhone size (small, standard, Max, and foldables such as an iPhone Duo or Fold), iPad in full
screen and in Split View, Slide Over and Stage Manager windows, and portrait and landscape.

- Lay out from the space available (size classes, `ViewThatFits`, adaptive grids), not from a
  device name or a fixed screen width.
- Check the smallest iPhone, the largest iPhone, an unfolded or split screen, and iPad before
  calling a screen done. Larger Dynamic Type sizes must not clip or overlap.

## Liquid Glass menus with icons

- Every menu item's icon must be the same **color** as its text: label-colored text gets a
  label-colored icon, and a destructive item's red text gets a red icon. Menus tint icons with
  the app's accent (set at the root) while the titles stay in the text color, so don't use
  `systemImage:` in menus. Use the helpers in `DesignSystem/MenuIcon.swift` instead:
  `Button("Rename", menuIcon: "pencil") { … }`, `Menu("Sort", menuIcon: …) { … }`,
  `Toggle("…", menuIcon: …, isOn: …)`, or `Label { Text("…") } icon: { Image.menuIcon("…") }`
  (pass `role: .destructive` for red). The only exception is a color swatch in a color picker.
- When a menu item is a checkmark selection (picking one option, or toggling options on and off),
  the checkmark goes on the **right** side of the item. iOS 26's native menus draw selection
  checkmarks on the left (a `Picker` or `Toggle` inside a `Menu`, or a `checkmark` symbol in the
  item's label, which takes the icon's place), so selection menus use the app's right-checkmark
  menu component instead — this is the one place a custom control beats the native one.
  Here that's `ChoicePopover` (DesignSystem/ChoicePopover.swift).

## Sheet buttons

- A sheet with both Done and Cancel at the top (Save, Add and Create count as Done) uses
  `SheetDoneButton` and `SheetCancelButton` from `DesignSystem/SheetButtons.swift`:
  - **Done** is a circular checkmark button filled with the app's color, with a white icon.
  - **Cancel** is a circular X button with no colored background, its icon in the text color
    (black in Light Mode, white in Dark Mode).
  Put them in `.confirmationAction` and `.cancellationAction`:
  `ToolbarItem(placement: .confirmationAction) { SheetDoneButton("Save") { save() } }`.
  Keep the title (it's read by VoiceOver); only the icon shows.

## iPad sidebar

- When the tab bar opens into the left sidebar on iPad (`.sidebarAdaptable`), every tab's icon
  is the same color as its name: black in Light Mode, white in Dark Mode, never the app's tint.
  The sidebar tints icons with the app's color, so on iPad (regular width) build each tab's
  label as `Label { Text(title) } icon: { Image.menuIcon(symbol) }` (from
  `DesignSystem/MenuIcon.swift`). The iPhone tab bar keeps plain symbols, so the selected tab
  still shows in the app's color.

## Prefer native

Prefer native iOS capabilities and components over custom ones: system controls, `List`/`Form`,
`Menu`, `Picker`, sheets, toolbars, search, `ShareLink`, SF Symbols, system colors and Dynamic
Type, and Apple frameworks over hand-built versions. Build something custom only when nothing
native does the job, and match the system's look and behavior when you do.

## iCloud sync

- All of the user's data syncs with their iCloud account (CloudKit, in their private database).
- A change made on one device is pushed out to every device on the same iCloud account, and to
  the family through Family Sharing / CloudKit sharing where the data is shared. Use CloudKit
  push (silent remote notifications and database/zone subscriptions, or `NSPersistentCloudKitContainer`
  / SwiftData's CloudKit sync) so other devices update without the user doing anything.
- Every screen that shows data that lives in iCloud supports pull to refresh (`.refreshable`),
  which fetches the latest changes from iCloud before it finishes.

## Confirmations

When an action needs confirming (deleting, erasing, signing out, leaving), always use a native
alert (`.alert` with a `role: .destructive` button and a Cancel button) rather than a native
popup or popover (`.confirmationDialog`, action sheet, `.popover`), unless explicitly told
otherwise.

## Hearth household

The family (people, photos, birthdays, allergies, diets, likes and dislikes) is the **Hearth
household**: one record set in the family's iCloud (container `iCloud.com.stephenwarren.hearth`,
zone `Household`), shared with the family by a CKShare. `HearthHouseholdStore.shared` reads and
edits it, and every Hearth app on the device sees changes at once through the app group.
`HearthHouseholdView`, `HearthPersonView`, `HearthPersonEditor` and `HearthInviteSheet` are the
screens for it; don't build app-specific versions.

- **Privacy rules (never break these):**
  - Family profiles never go to a Hearth server. The server may hold membership (who's in a
    household, a seat id and a name where a feature needs one), nothing more.
  - Birthdays, allergies, diets, likes, dislikes and household restrictions are stored in
    CloudKit `encryptedValues`. A new sensitive field goes there too.
  - An AI request gets only `store.aiContext()` (`HearthAIContext`): ages, roles and food rules,
    no names, no photos, no birthdays, for that one request. Nothing is logged or saved.
  - Never put household data in analytics, logs (`privacy: .public`), crash reports or
    notifications' text beyond a first name.
- **Allergies are hard rules.** Anything that suggests food must never suggest one.
- **There is always a household** (a household of one is fine). New people get HearthKit's
  `HearthHouseholdOnboarding` step in onboarding; the root has
  `.hearthHouseholdRequired(isActive:accent:)` so nobody uses the app without one. Never build
  an app-specific person editor or a no-household fallback.
- **One invite for everything.** An app that shares its own data does it as an app zone in the
  Hearth container (`HearthZoneParticipant` + `HearthAppSharing`), shared automatically with the
  household. Never create another CKShare or invitation flow.
- **One entry, named "Household"** (`HearthHouseholdLabel.title`, symbol
  `HearthHouseholdLabel.symbol`), at the top of Settings or Profile, opening
  `HearthHouseholdView`. App-specific details about a person go on their page through
  `.environment(\.hearthPersonExtras)`, not on a separate screen.
- **The app's own people mirror the household.** Keep the app's model (Caloma's `Member`, etc.)
  and link it by Hearth id: `store.localID(of:app:among:)` to find a person's record here,
  `store.linkHere(_:app:localID:)` to link one (shared link when the app's data is the family's,
  per-device link otherwise), `store.member(app:appID:)` to go back. Only add people when
  `store.canEditEveryone`, so two phones don't both create one.
- **Edits go through the household.** For a linked person, edit with `HearthPersonEditor`; the
  mirror copies the change into the app.
- Invitations: the root view has `.hearthHouseholdInvitations()`, and the scene delegate hands
  CKShare metadata for the Hearth container to `HearthHouseholdStore.shared.receive` (see
  `HearthHouseholdStore.handles`).
- **In Suffice:**
  - **The budget is the app zone `Budget`** in the Hearth container, synced on the household's
    engines: `HouseholdSync` is a `HearthZoneParticipant`, registered in `SufficeApp.init` before
    `HearthHouseholdStore.shared.start(app:)` (AppRoot's task, followed by
    `HouseholdSync.shared.householdDidStart()`). `HearthAppSharing.update(app: .suffice,
    zoneName: "Budget", title: "Budget", audience: .adults)` shares it with the household's
    parents and adults (owner) or accepts the family's (everyone else). Kids aren't in the
    budget. Suffice has no CKShare, invitation, sync engine or container of its own
    (`iCloud.com.stephenwarren.suffice` is no longer used).
  - Joining a family's household replaces the budget on the device with the family's; the
    person's own stays in their private Budget zone and comes back if they leave. Each family's
    budget keeps its own record details on the device (`HouseholdSync.Location.fileKey`), and
    nothing queued for one zone is ever sent to another.
  - `Services/SufficeHearthHousehold.swift` mirrors parents and adults (role != kid) onto
    `Member`, with the nearest `MemberColor` and the household's photo. There's no Suffice
    person editor. Suffice's own people went into the household once, when it was created (the
    setup screen reads what Suffice published); the mirror never adds people to the household.
    Suffice-only facts (who made a transaction, spending by person) stay on `Member`.
  - "This is me" (`SettingsKey.currentMember`) follows the household's `me` (the linked
    `Member`); people pick themselves in Household.
  - Profile's one Household row opens `HearthHouseholdView(accent: Brand.green)`; a person's page
    shows Suffice's section (`Features/Profile/SufficePersonExtras.swift`).
  - Suffice's `Member` records use the CloudKit type `BudgetMember`, because the container's
    `Member` type is the household's, with different fields. A new synced type must not reuse a
    record type name another Hearth zone uses.

## Shared Hearth code

These are copies: in `Services/Hearth/`, `HearthShared.swift`, `HearthApps.swift`,
`HearthSync.swift`, `HearthPicker.swift`, `HearthIconLibrary.swift`, `HearthAccount.swift` and the
four `HearthHousehold*.swift` files, plus `Assets.xcassets/Hearth`. Edit the originals in
`~/Developer/hearthkit` and run `bash sync.sh` there; never edit a copy. App-specific Hearth code
(such as `HearthLink.swift`) also lives in `Services/Hearth/` and isn't touched by the sync.
