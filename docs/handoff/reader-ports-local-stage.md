# Reader Ports: Local Stage Only

Date: 2026-11-03

## Stop Boundary

Update: the user confirmed omp is finished and authorized starting acceptance.
Current work and evidence boundaries are in `reader-ports-acceptance.md`.
The remaining text records the original local-stage handoff, not a current ban
on local/live acceptance. It remains true that no port is an accepted iOS release.

The user requested Picacomic first, then WNACG/JMComic and E-Hentai, explicitly asking
that these ports stop at the local implementation/test stage until omp finishes
its concurrent Copymanga work. Do not resume cloud builds, live-site/account
acceptance, repository distribution, commits, pushes or releases without the
user's follow-up. Preserve all concurrent work and keep reference repos read-only.

This document is separate from CURRENT_STATUS/ROADMAP and the Copy acceptance
workflow to avoid interfering with that work. It does not supersede historical
release evidence. These ports are NOT verified iOS releases.

## Integration

- Flutter/Dart app. iOS executes compatible JS/API rules in isolated WebKit;
  it cannot install/execute Android APK/DEX extensions.
- Bundled catalog: `assets/catalog/index.json`. All four new sources explicitly
  declare `nsfw: true`, remain excluded by the existing exclude-NSFW filter,
  and require explicit catalog installation, not automatic startup activation.
- Rules: `assets/rules/picacomic-js.json`, `assets/rules/wnacg-js.json`,
  `assets/rules/jmcomic-js.json`, `assets/rules/ehentai-js.json`; all version 1.0.0.
- `lib/core/source/source_providers.dart` selects the Picacomic/JM native
  gateways. WNACG and E-Hentai use the generic JsSource runtime.
- JM image restoration is scoped to `sourceId == 'jmcomic'` in the production
  `DioSourceHttpClient.fetchBytes` path. Reader/preload, manga downloads and
  Save Image use this path. Other source bytes remain untouched. Do not also
  restore downloaded PNG files a second time.
- No dependency/lockfile changes, native iOS changes, workflow changes, remote
  extension-repository changes or application version changes were made.

## Source Scope

### Picacomic

`lib/core/source/picacomic/` implements native signing, login, secure-store
session ownership tied to rule code/inputs, bounded 401 renewal, endpoint
restrictions and cancellation. Downloaded JS receives neither passwords nor
tokens. Non-secret settings have an isolated UI under source management.

Implemented: newest/random/rank feeds, keyword/category search, read-only
site favorites, detail, complete episode/page pagination, quality and blocklist.
Uses official HTTPS API/system DNS (Android channel 1). Android's channel-2
plaintext DNS bootstrap is intentionally not implemented. Real account login,
real chapter/image requests and iOS WebKit/device behavior are unverified.

### WNACG / 绅士漫画

Reference: `../_refs/extensions-source/src/zh/wnacg/`, versionCode 5.
Default mirror from that reference: `https://www.wn07.cfd`.

Implemented: desktop-HTML lists, rankings, keyword search, online category
taxonomy, single-gallery chapters, paginated collection directories and inert
gallery image-list parsing. Downloaded site scripts are never executed.
Login/verification/empty content fail visibly instead of claiming success.

Not implemented/verified: website account cookies, logged-in-only categories,
automatic mirror-list updates, preferences/blacklist parity or real-site HTML
acceptance. Tags and categories cannot silently combine with keyword search
when the upstream site does not support that combination.

### JMComic / 禁漫天堂

Reference: `../_refs/extensions-source/src/zh/jinmantiantang/`, versionCode 63,
App protocol 2.1.12, fallback host snapshot dated 2026-10-28 in that reference.

`lib/core/source/jmcomic/` implements anonymous read-only API token signing,
AES-256-ECB/PKCS#7 response/server-list decoding, restricted HTTPS host discovery,
fallback snapshot, pacing, cancellation and source lifetime ownership.
Failed API hosts rotate on a subsequent explicit request, not an invisible retry.

Implemented: popular/latest/ranking feeds, keyword/JM-ID/redirect search, online
taxonomy, canonical parent albums, ordered chapters and image URLs. The byte
host reverses the upstream strip permutation, including remainder rows and
MD5 row-count thresholds. Covers, old unsplit images and GIFs pass unchanged;
restored static images are lossless PNG with pixel/size bounds.

Not implemented/verified: account favorites, login, automatic/manual check-in,
complete preference/filter parity, real API/CDN images, simulator memory,
decode throughput, offline round trips or real iOS reading.

AES reuses the locked archive package's internally vendored AES engine,
isolated in `jmcomic_crypto.dart`, with an independent Python/PyCryptodome
test vector. Recheck that internal API before any future archive upgrade.

### E-Hentai (Public Galleries Only)

The local extensions-source checkout has no standalone E-Hentai extension.
Read-only protocol reference: `../_refs/komikku/app/src/main/java/eu/kanade/`
`tachiyomi/source/online/all/EHentai.kt`, a Komikku built-in source.

Implemented: popular (explicitly single-page), latest/search cursor traversal,
compact/extended/thumbnail list parsing, namespace queries, gallery-URL search,
metadata and tags, bounded parent/version chapters, complete thumbnail-page
traversal and numeric image ordering with gallery/page identity checks.
Empty/missing/duplicate/incomplete content fails instead of claiming success.

The rule returns canonical public `/s/<key>/<gid>-<page>` references rather than
expiring CDN links. `lib/core/source/ehentai/ehentai_image.dart` resolves `img#img`
only when `DioSourceHttpClient.fetchBytes` is called with `sourceId == 'ehentai'`.
Reader/preload/download/save therefore share one lazy path; a long gallery does
not immediately fetch every image page. SourceNetworkImage actually decodes a
synthetic PNG through that production path in the regression suite.

The lazy resolver drops caller credentials, retains only public UA/Referer,
rejects write methods, refuses page/CDN redirects and respects cancellation. Metadata
requests for this source also disable redirects. Script text is not executed.
Quota/509 placeholders, verification/login pages and missing images are failures,
not triggers for automatic quota bypass, `nl` alternate-server retry, account
login, paid original-image download or ExHentai access.

Not implemented/verified: login/cookies, ExHentai, favorites sync, full Android
settings/filter parity, historical metadata merging, original downloads,
restricted galleries, real current HTML/CDN/network acceptance, real offline
round trips and iOS simulator/device reading. Insecure HTTP image links are
explicitly rejected (including any HTTP-only H@H endpoint); HTTPS only for this
local-stage port. Installed apps need a host build with this resolver; distributing
the JSON alone to an older host is insufficient for reading.

E-Hentai-only local contracts: `test/ehentai_js_rule_test.dart` and
`test/ehentai_image_test.dart`. Standalone future WebKit entry:
`integration_test/ios_ehentai_test.dart`, not wired to omp's cloud workflow and
not executed on iOS. All HTTP fixtures use synthetic metadata/images and no
real account credentials or site content.

## Local Verification

Selected serial Flutter regression run: **182 passed, 0 failed, 0 skipped**.
This is not the full repository test suite and does not prove live/iOS behavior.
Final `flutter analyze --no-pub`: no issues found. `git diff --check`: passed.

The run includes:

- `reader_ports_registry_test.dart`: real catalog installation and production
  factory selection, source isolation and NSFW metadata, with in-memory DB.
- `wnacg_js_rule_test.dart`, `jmcomic_client_test.dart`,
  `jmcomic_js_rule_test.dart`, `jmcomic_image_test.dart`: 39 source tests.
- Existing Picacomic tests: 21 tests, rerun after small lint/type cleanup.
- E-Hentai rules/image resolution: 40 tests, including reader decoding,
  Save Image, cancellation, quota failures and rejected page/CDN redirects.
- Existing catalog/update, network-image/save-header, download-boundary,
  Copy JS/host/cover regressions; no changes to Copy test files.

Protocol rules execute in real desktop QuickJS with fake site responses.
JM AES and MD5 thresholds have independent Python vectors; image tests use
synthetic RGBA rows and Flutter's real codec/canvas, checking every pixel.
No real account data or site content is used in these fixtures.

Standalone future iOS entries, deliberately NOT wired into omp's workflows:

- `integration_test/ios_picacomic_test.dart`
- `integration_test/ios_reader_ports_test.dart`
- `integration_test/ios_ehentai_test.dart`

These entries reuse contracts with production IosJsRuntime; they have not
been run on macOS/iOS. No IPA or screenshot/recording acceptance exists for
these ports. After the user's go-ahead, verify actual current protocol/APKs,
real network and complete reader/download/image behavior, then run the iOS
contracts and visual acceptance before claiming distribution readiness.
