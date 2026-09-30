# Contacts

## Invariants

- Off by default. Disabled means no Contacts fetch, observer, thumbnails or retained contact index.
- `AppCore` owns `ContactsStore` and `ContactsCoordinator`; views act through the coordinator.
- Both palette and Settings hosting hierarchies inject `ContactsCoordinator` into their environment.
- Only native `CNContactStore` reads contacts. No shell, AppleScript, private API or dependency.
- Unified contacts become lightweight `ContactEntry` values; `CNContact` objects never survive a fetch.
- Contact contents and thumbnails stay in memory. No persistence, networking, analytics, logging or AI.
- `EntryNaming`, `LauncherMatch` and `LauncherOrder` own all fuzzy matching and transliteration.
- Shared ranking records contact IDs and frecency, never contact query strings or contact contents.

## Permission flow

Enabling Contacts or invoking its enabled command requests access only when authorization is
`notDetermined`. Launching the app never requests it. The explicit Enable Contacts switch stays on
if access is denied, so Search Contacts can explain the problem and offer Open System Settings.
`restricted` explains the policy restriction without offering an ineffective grant button.

The Settings pane and permission screen offer Grant Access for an undecided grant. Returning from
System Settings and reopening the palette/pane rechecks authorization; it does not poll. The usage
text is in `Info.plist`; the hardened runtime declares `personal-information.addressbook`.
Disabling during an outstanding system prompt cannot dismiss Apple's prompt, but its result cannot
restart a disabled feature.

## Store lifecycle and change observation

`ContactsStore.start(options:)` observes `CNContactStoreDidChange` only with authorized access.
A burst debounces for 250 ms. One detached enumeration runs at a time; overlapping refresh requests
collapse into one trailing fetch. A generation guard rejects a fetch finishing after disable.
Failures clear the index and surface a retry message; reopening the command retries.

A lazily owned, thread-safe `CNContactStore` fetches unified contacts with exactly the required keys. It builds
search profiles off-main, then publishes the finished entries on the MainActor. Typing never fetches
contacts. `stop()` removes the notification token, cancels refresh/thumbnail tasks and releases arrays,
result memos, native store and the bounded image cache. Permission changes are rechecked on opening a surface.

## Launcher integration and search fields

`Search Contacts` is an ordinary built-in command owned by Settings › Contacts. Its alias, hotkey
and launcher checkbox use `FeatureCommandsSection`; disabling the feature also disables its chord.
The command remains available when Show in launcher is off. Individual contacts enter root search
only with the feature and that preference enabled, under the Contacts kind and section.
The category's visibility switch still applies downstream to root results.

Both screens use `AppIndex` ranking and the user's Search sensitivity. Prepared profiles contain:

- Title: Apple's `CNContactFormatter` full name, falling back to organization, email, phone, Unnamed Contact.
- Alternate titles: nickname and name components.
- Subtitle: organization, primary email or phone, subject to the corresponding search option.
- Keywords: enabled email/phone/organization fields and job title.

Phone fields and phone-only queries remove formatting and fold decimal digits. This matches
`+49 170 123456`, `49170123456` and `49 (170)/123-456`. Country/trunk-prefix equivalence is not inferred:
Contacts has no reliable country context for arbitrary phone strings. Names use Tinycast's existing
fold and transliteration; no extra Müller/Mueller rule is introduced.

Result rows show organization, then email or phone as context even when a search-field option is off.
The shared launcher row and list own selection, scrolling, hover, keyboard and visual tokens.
Queries cap results at the launcher's existing 200; an empty query lists all authorized contacts.

## Actions

Return and ⌘Return open Contacts.app using LaunchServices and its public bundle identifier.
There is no documented identifier-based Contacts deep link used here, so opening does not guarantee
that Apple selects the highlighted person. No private addressbook URL is constructed.

⌘K offers Copy Name, Copy Primary Value and Copy All Contact Details, plus actions for every labeled
email, phone, postal address and website. Apple's labels and address formatter are localized.
`mailto:`, `tel:` and `facetime:` actions appear only when LaunchServices finds a handler; macOS may
ask before placing a call, and telephone calling depends on the configured calling provider. Ambiguous extension/pause strings
remain copyable but do not offer a call that would silently concatenate their digits.
Apple Maps receives a percent-encoded address query, explicitly opened with Maps.app. Websites accept
only HTTP/HTTPS. Copy actions preserve formatting and use Tinycast's existing marked copy, so its clipboard history
does not persist contact contents.

⇧⌘C copies the primary email, then phone, then name; ⌥⌘C copies the name. These follow existing Tinycast
row-shortcut conventions, leaving ⌘C available to the search field. No separate detail screen is added;
the action panel lists values and Copy All Contact Details includes every field.

## Settings and backup

Enable Contacts defaults off. Show in launcher, Show contact photos, Search phone numbers,
Search email addresses and Search organizations default on. The preference switches are disabled
while the feature is off; the enable switch remains available.

All display/search settings mirror into settings.json and settings backups. Enable Contacts is a
local permission gesture and has no settings-file key or backup field. Importing preferences does not
request access or enable the feature, and no contact contents travel in backups.

## Privacy and memory

The index has no contact image data. Visible avatar views request only `thumbnailImageData`, never
full `imageData`, with a cache bounded to 64 images and a 2 MB cost limit. Turning photos off releases that cache. The main index, root slice and result arrays share Swift
value storage; there is no second contact database. Profile construction happens once per refresh.
Disabling clears the store and launcher result memos so stale snapshots cannot hold address-book data.
User-invoked Mail, calling, Maps and browser actions hand only their explicit destination to the chosen
app; Contacts Search itself never performs network requests.

## Tests

`contacts-test` compiles the shipped model and launcher matching/ranking sources. It covers fallback
names, every search field, numeric formatting, optional search switches, existing international-name
folds, actions, IDs, privacy of ranking and a synthetic 10,000-contact match pass.
`contacts-store-test` compiles the native reader and store with the launcher's value shape supplied by
the harness. In-memory native contacts verify Apple formatting/labels. Injected permission/fetch
functions verify denied/restricted states, disabled cost, root visibility, store-change deletion,
debouncing, refresh serialization and disable/re-enable during in-flight work.

Manual checks on a signed Dev build:

1. Start with Contacts off: no command, entries or permission prompt. Enable in Settings and grant access.
2. Open Search Contacts, type a name/nickname/company/email/phone; verify live results and thumbnails.
3. Press Return and ⌘K; try every available labeled action and the copy chords.
4. Turn Show in launcher off: root people disappear; the command and its shortcut continue working.
5. Edit/delete a contact in Contacts.app with the palette open; verify the refreshed result.
6. Deny/revoke access, reopen: verify the permission state. Disable during a refresh: no stale entries return.
7. Import a backup into a profile with Contacts off: display preferences carry, enablement does not.
8. Measure idle/peak memory and leaks with a real large address book and after closing the palette.

The harness benchmark is synthetic; it does not replace live UI, TCC, leak or memory measurements.
