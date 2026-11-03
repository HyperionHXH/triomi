# Reader Ports Acceptance

Started: 2026-11-03. Supersedes the stop boundary in
`reader-ports-local-stage.md`: the user confirmed omp finished and requested
acceptance of Picacomic, WNACG, JMComic and public E-Hentai.

## Gates

1. Preserve completed Copy work and existing release evidence. Check current
   protocol references and production registry/transport on the local machine.
2. Run explicit anonymous metadata preflight, then select verified non-explicit
   public samples before any image/visual acceptance. No arbitrary trending
   gallery screenshots, credentials, verification bypass or quota bypass.
3. Repair demonstrated failures and run source contracts, full Flutter suite,
   analyzer and original-platform builds serially.
4. With commit/push authorization, run the pinned macOS/iOS workflow on the
   exact candidate, including WebKit contracts, native bridge, production
   reader/download/save paths and UI screenshots/video. Download and inspect
   same-run artifacts before claiming iOS acceptance.

## Authorization And Evidence

- Local source/test/network acceptance is authorized by the follow-up.
- After the explicit commit/push/Actions question, the user replied to continue;
  this round's candidate commit/push and GitHub Actions are authorized. No
  Release or public catalog publication is included. No branch switch/cleanup.
- Picacomic needs a real account. Empty-store login guard can be tested;
  account-required behavior is not a live reading pass. Never request passwords
  in chat or use another application's stored credentials.
- `tools/live_reader_ports_probe.dart` exercises the actual source factory,
  isolated in-memory database/preferences/store, production QuickJS and Dio
  HTTPS. Default scope is metadata only. Reports exclude remote titles,
  response bodies, queries from URLs, request headers and image files.
- Reports live under ignored `release_ios/reader-ports/<UTC run>/`. Failures
  remain failures; `blocked_account` is distinct from a network/reading pass.
- Prior 182 passing tests are local synthetic regressions, not evidence of
  real upstream reading or this round's iOS execution.

## First Network Findings

Production preflight: `release_ios/reader-ports/2026-11-03T09-55-11.685264Z/`.
Picacomic correctly blocks without a session and issues zero requests. JM's
encrypted server list, discovery and search all return HTTP200; discovery and
search each parse 80 entries. Neither result proves image restoration or reading.
WNACG's old default has a receive timeout; public E-Hentai has a connect timeout.

Independent Python ordinary HTTPS, with certificate validation enabled and no
credentials: both old WNACG and E-Hentai time out directly but return HTTP200
via the machine's existing system proxy. This is a route comparison, not Dart
or iOS acceptance and does not modify global/app proxy settings. The reference
extension's official domain-list URL currently publishes `www.wnacg.buzz` and
`www.wnacg.site`; both new mirrors return HTTP200 directly and through the
existing proxy, with gallery markup. Reports are in
`release_ios/reader-ports/network-comparison/`. Update the fixed default and
recheck production Dart rather than silently retrying the failed request.

Default mirror updated to `https://www.wnacg.buzz`, keeping numeric gallery and
chapter identities unchanged. Regression failed against the old default before
the update. Production Dart retest is in
`release_ios/reader-ports/2026-11-03T10-14-35.461354Z/`: direct HTTPS discovery
20, search 24, both HTTP200.

E-Hentai's explicit-proxy production run reached real HTML and exposed two
implementation defects, each reproduced with a failing synthetic regression:
`inline_set=dm_e` sets a site preference and redirects with HTTP302, and real
navigation includes inert `javascript:enable_jump_mode(...)` anchors. The port
now parses the returned display layout without mutating its preference and
ignores (never executes) those controls. Redirect prohibitions remain intact.
After both repairs, production Dart discovery 66 and search 25 complete with
HTTP200 via the explicitly selected existing proxy. Direct reachability remains
failed/unverified; no account, image or iOS reading pass is implied.
Accepted metadata report:
`release_ios/reader-ports/2026-11-03T10-19-46.991722Z/ehentai-metadata.json`.

The existing comprehensive iOS entry now imports the four-source contracts.
E-Hentai image byte/decoder contracts now use the same portable widget/real-time
wrapper as the existing source suites. Added production Picacomic settings UI
save/cancel tests; no real credentials. These changes are not yet iOS-executed.

The new settings tests caught a real disposed-controller assertion on both save
and cancel during the dialog exit animation. The function now awaits the pushed
DialogRoute's `completed` future before disposing its controller. Both original
tests pass without weakening their exception checks.

## Local Verification This Round

- Full serial Flutter suite before the additional mirror/search/settings
  regressions and repairs: 1916 passed, 4 skipped, no failures (718 seconds).
- Final changed-source selection after those repairs: 106 passed, no failures
  or skips, including the production registry, all four rules, gateways,
  synthetic image decoding/restoration and settings save/cancel.
- Python iOS tooling regression: 32 passed. These are host-tool tests, not iOS.
- Final `flutter analyze --no-pub`: no issues (20.5 seconds).
- Final analyzer and original-platform debug builds are recorded separately in
  `release_ios/reader-ports/local-acceptance-20261103/`. No app installation,
  device data change, commit, push, CI execution or release has occurred.
- The full-suite count and final focused count are separate runs, not an
  invented combined total. No actual iOS execution or real offline round trip
  has occurred for these four ports.

## Authorized Cloud Candidate

The user replied "continue" after the explicit commit/push/Actions question.
Current round now includes a candidate commit/push, never tags/releases or
public catalog updates. Windows debug and Android debug both build locally;
Android SDK was already installed and required process-only ANDROID_HOME /
ANDROID_SDK_ROOT pointing to `C:\Android\sdk`. No device installation.

Additional production-path acceptance (synthetic, no public images): all four
rules now traverse actual SourceRegistry, JsSource, gateway, image byte host,
DownloadService, manifest/files, Save Image bytes and offline decoding. Four
round-trip tests pass; one production UI test passes through four actual manga
readers and Picacomic settings. New host tooling has 35 passing Python tests,
latest analyzer has no issues. Full final suite will be rerun serially.

Cloud workflow preserves original native/Copy/17-source/56-state gates and
adds a distinct six-state geometric fixture visual tour plus anonymous real
metadata audit. Neither is labeled live-image acceptance. Metadata account or
network failures remain visible; no failure-exclusion policy is added for these
sources. Diagnostic artifacts upload even on failure, candidate IPA uploads
only when all required workflow gates succeed. No release is triggered by a
branch push. Existing Copy capture tools are reused without changing their code.

## Progress

- [x] Confirm completed Copy baseline: `286d537` documents accepted iOS178;
  existing dirty files are the four reader ports, not concurrent Copy changes.
- [x] Anonymous production metadata preflight and protocol diagnosis; preserve
  direct-network failures and Picacomic's account requirement separately.
- [ ] Explicit safe sample reading/download/save acceptance.
- [ ] Full local regression and platform builds.
- [ ] Exact-candidate iOS contracts, visual inspection and artifacts.
