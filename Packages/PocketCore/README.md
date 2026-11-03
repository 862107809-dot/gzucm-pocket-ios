# PocketCore

Foundation-only Swift package for GZUCM Pocket's academic models, parsers and authenticated HTTPS client. Minimum iOS 18; no third-party runtime dependency.

Upstream protocol source: [Hello-Minecraft/gzucm-pocket](https://github.com/Hello-Minecraft/gzucm-pocket), commit `b36a8a7846a2d685d8d37a473032c360d35210ed`, MIT © 2026 朱致辉. Original notices are retained in the application's App/Resources/ThirdPartyNotices.txt.

## API

```swift
let client = SchoolClient()
await client.setCookies(cookiesFromSchoolWKWebView)
let result = try await client.fetchAcademicData(campus: .undergraduate, semesterCode: nil)
// Surface result.warnings; some nonessential sections may have failed.
await client.clearSession()
```

`AcademicSnapshot` contains school calendar, dated sessions, course/level/fitness grades, exams, timestamp, warnings and typed `failedSections`. Dates use the Asia/Shanghai Gregorian calendar, independent of the device's timezone. Models are value types, Codable and Sendable. IDs are deterministic; no credentials or complete server responses are retained.

## Protocol decisions

- Undergraduate school weeks run Sunday–Saturday. The app uses Monday–Sunday. Actual `qsrq` dates determine the app week. An extra school week is queried to retain the final Sunday. Total-table fallback applies the same rule.
- At most three week requests run concurrently. Failed weeks remain visible through warnings. Unauthorized responses stop the sync. A full-table fallback is attempted only if every weekly request failed, and its missing detail is announced.
- Each score section has a bounded request. Course records with nonnumeric/unpublished scores are skipped with an explicit warning, rather than assigned an invented number. Missing/nonfinite GPA is represented by `gpaAvailable=false` and excluded from the estimate, with a warning. GPA is an estimate using the upstream passed compulsory/limited-elective credit weighting, not an official school aggregate.
- Graduate terms come from `bindterm`; numeric codes cannot be inferred from the date. The grid is queried week by week, merging consecutive units while retaining teachers/rooms. A 20-week query window is an explicit inherited assumption. The first Monday is inferred by majority vote from dated courses and requested week numbers. An empty dated schedule cannot establish its calendar and returns an explanation. Graduate grades are based on upstream's unverified field mapping, and should be checked against the school page. Do not display a graduate GPA claim.
- Session cookies keep domain/path identity in an ephemeral URLSession cookie jar. HTTPS redirects stay on the original host. CAS redirects, HTTP authentication errors, HTML login responses and JSON `code=-401` become `.unauthorized`. Clearing a session invalidates/cancels the old URLSession and replaces its cookie jar. An inherited task-local generation rejects subsequent requests from stale sync operations.
- The app must clear its WebKit session, cached school data and pending reminders as well as calling `clearSession()` on logout. The app should preserve existing data for sections listed in `failedSections` when refreshing the same campus/semester and display the warnings.

## Validation

On a Mac with Swift/Xcode installed:

```sh
cd Packages/PocketCore
swift test
```

The XCTest suite covers detailed schedule fixtures, Sunday/week boundaries, the final Sunday, total-table fallback parsing, calendar inference, expired auth, malformed responses, score/GPA semantics, privacy-field selection, graduate mixed-cell HTML/continuous periods, deterministic IDs, class times and form encoding. The weekly fixture is derived from the upstream's already deidentified fixture and all teacher names are replaced again with example labels. Other fixtures are synthetic and contain no account data.

No live account was used. Windows host lacks a Swift compiler; tests are supplied for Mac/CI and must not be reported as executed here.
