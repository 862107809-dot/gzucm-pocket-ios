# Native school sign-in and portals

`SchoolLoginView` now offers native undergraduate QR sign-in and an official school password WebKit page. The QR protocol is implemented in PocketCore/SchoolQRClient.swift, with a request-local ephemeral jar, five-minute challenge, pinned-host completion redirects and a successful protected timetable probe. The UI generates its QR image locally, pauses polling while backgrounded, supports user-driven sharing to the system sheet, and cancels when switched/closed. Cookie handoff freezes mode switching and dismissal until the verified school cookies finish replacing the prior JW/parent-domain JSESSIONID entries. No password handling is injected. Graduate sign-in remains the official password portal.

`SchoolMessagesPortalView` opens the official authenticated school homepage and follows only an actual, same-origin rendered school message menu. No unverified message-list endpoint or unread count is invented. Its page remains visible when automatic menu discovery is unsupported.

`EcardPortalView(onSnapshot:onClose:)` opens the visible school electricity page in the same app-private `WKWebsiteDataStore.default()`. It does not copy ecard cookies into URLSession. Bundle `App/Resources/EcardBridge.js` as `EcardBridge.js` in the main app bundle. Exclude `App/Web/Tests` and this README from source compilation.

The document-start script intercepts real XHR/fetch responses on the official power-fee page. Since the own-room balance can be server-rendered, populated duplicate `#powerTips` elements are also read. A missing value remains missing; genuine zero and negative balances are retained. Current API building/room labels take precedence over the stale visible room label.

For monthly detail pagination the script takes the school's own rendered `toDailyDetails` link, keeping its query and token inside WebKit. It uses the upstream verified `getDailyDetails` endpoint, requests at most four 30-row pages per month, and also requests the preceding month during the first seven days. No signature or token is synthesized. If the verified link is absent, the visible official page remains available for the user to query or bind their room. Data is cached only as normalized balance, labels and daily rows.

Native messages are restricted to the main frame, HTTPS and the exact ecard hostname. Responses are restricted to successful same-origin power-fee requests. Balance and daily responses can arrive in either order and are merged by internal room context in memory. A request pending during a room change cannot attach its old response to the new room. Internal room keys are never persisted in `PowerSnapshot`.

`PowerSnapshot.isComplete` remains false during incremental balance/daily updates and is true only after every intended month has been paginated successfully, including valid empty results. A failed or truncated month never emits the `complete` bridge event. App notification scheduling must require `isComplete`. A new balance or daily batch clears the completion flag until another successful completion; currency balances are not converted to days (`isEnergyUnit` / `estimatedDays`). Older caches decode the new flag as false.

`WebsiteDataReset.clear()` removes the app's WebKit cookies, local storage and caches at logout. The app owner must also clear academic URLSession cookies and app data. Callers should dismiss active browser sheets before resetting.

Verification on Windows:

```sh
node --test App/Web/Tests/EcardBridge.test.cjs
```

The tests execute the shipped JavaScript, not a second implementation. Native Swift/WebKit behavior still requires Xcode compilation and school-account validation on iOS. Third-party top-level login redirects and non-HTTPS navigation are deliberately unavailable in this embedded school window. Changes to school pages may require parser updates; an unsupported page never generates an invented zero balance.
