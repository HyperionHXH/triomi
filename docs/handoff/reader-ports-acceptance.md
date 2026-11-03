# Reader Ports Acceptance

Started: 2026-11-03. Supersedes the stop boundary in
`reader-ports-local-stage.md`: the user confirmed omp finished and requested
acceptance of Picacomic, WNACG, JMComic and public E-Hentai.

## Current Follow-Up: Build Native Gateway Host179

User now authorizes app gateway completion, commit/push and iOS compilation.
Supersedes prior catalog-only/no-new-IPA restriction, not authorization to move
old tags or overwrite Release assets. Existing native implementations from67ce2cd
are retained. Host179 adds versioned requiresHost contracts, installer/import/
load checks and UI compatibility, with JM/Pica rules1.0.1. Private account/relay
and disabled workflow drafts remain local, not committed; no account Secrets.
Track exact new app commit/run; do not substitute earlier178 candidate artifacts.

## Latest Delivery: All Four Published, Catalog Only

Latest user authorization explicitly requires both JMComic and Picacomic and
allows commit/push. This supersedes the earlier exclusion/pending-auth plan.
Plugin repository `HyperionHXH/Mihon-Extensions` main commit
`ba207926d89ae81a0f75ff6583e71695fe933d6c` publishes22 rules: unchanged18 plus
WNACG1.0.0, generic-host E-Hentai1.1.0, JMComic1.0.0 and Picacomic1.0.0.
All22 public HTTPS downloads match catalog identity/version/SHA-256 and local
bytes. Catalog CI41657109247 and security CI41657109014 succeeded.

Official178 commit0c27925 supports WN/EH, NOT JM/Pica. Those two need native
API/image/account support present in candidate67ce2cd (same0.12.0+178 version
label; distinguish by commit/hash). Names visibly warn about native gateways;
index/provenance include hostRequirements. Old clients IGNORE that field and
DO NOT block installation. A catalog entry does not supply missing host code.
No new IPA/app commit or push; dirty application work and read-only references
are preserved. No account Secrets or signing constants in the catalog.

Verification:39 plugin Python tests; generation/hash check and125-file
prospective tracked+untracked security scan passed;38 old rule/Android index
files unchanged. Exact old178 generic host still passes8 installation/order/
unsafe-image/quota/challenge tests. Public HTTPS production installer -> isolated
DB -> current production factory -> synthetic reading passes all4 sources;
JM pixels match canonical geometry, Pica unauthenticated API count is zero.
No real account/upstream-image acceptance or new actual-iOS acceptance claimed.
Both Dart probes analyze cleanly.

Probes: tools/catalog_reader_native_probe.dart (TRIOMI_PUBLIC_CATALOG=1 downloads
only GitHub rules/index; account/site/image seams stay synthetic) and
tools/legacy_reader_catalog_probe.dart. Evidence under
release_ios/reader-ports/catalog-only-20261103/: public-four-reader-catalog.json,
public-catalog-native-factory.log and published-four-reader-acceptance.json.
Earlier local20-entry audit artifacts remain historical, not current status.

## Resume And Account Safety Boundary

The latest user request explicitly permits omitting Picacomic if GitHub Secrets
would create a safety concern. Do not provision, inspect, rotate or consume
account secrets. Real Picacomic login/Keychain/account acceptance is excluded;
its anonymous login guard and synthetic contracts remain separate evidence.
The unfinished local account relay and integration files are preserved, not
executed or added to the release. The draft `picacomic-account` job is hard
disabled (`if: false`), its manual input and secret bindings are removed, and a
host regression checks this boundary. No safety/scanning control is bypassed.

The actual source candidate is `67ce2cd4b9b9c0a87dcf556d0eb3aa9951634da2`.
Its existing iOS run is `41627388664`; it contains no account-secret workflow.
At resume, device Release compilation/packaging, native bridge, JavaScriptCore
stress and comprehensive iOS integration had succeeded. The run subsequently
finished successfully; downloaded evidence and limitations are recorded below. This
session does not commit, push, dispatch another run or publish a release.

The previously overlooked final local candidate log records **1926 passed,
4 skipped** in 521 seconds, and the Python log records 122 passed. These are
historical local results, not a substitute for a fresh run or iOS evidence.
Fresh results and any cloud failures will be recorded separately below.

### Fresh Local Verification

- Full serial Flutter: **1926 passed, 4 skipped**, 504 seconds. No account
  relay or live-image test is in this run.
- `flutter analyze --no-pub`: no issues, 114.6 seconds; preserved draft Dart
  file is included in static analysis, not executed.
- Python tools: **128 passed**, 12.664 seconds, using the repository's
  `tools/requirements-dev.txt` constraints in ignored `build/python-test-deps-repo/`.
  Initial missing OpenCV and an out-of-range trial dependency run remain in
  separate logs and do not replace this final constrained-environment result.
- Metadata collector now independently rejects failed reports, missing or
  duplicated sources, nonzero Picacomic guard requests and any reading-pass
  claim. A zero Flutter exit alone cannot bless invalid reports. Host tests
  failed before implementation and all nine reader-port tool tests pass now.
- Windows debug and Android debug build again, 25.3 and 20.9 seconds;
  no application was installed and no device data was touched. Existing CMake
  policy and Flutter/Kotlin migration warnings remain, not build failures.
- Encoding check: zero errors. `git diff --check`: no whitespace errors.
- Generic private-key/GitHub-token pattern scan: 1440 source files, no
  unreviewed matches. Two known validator/test marker files are reviewed;
  the ECH `cacert.pem` is 118 public certificates, not private material. This
  limited scan reads no personal account/signing files and is not proof of
  absence of every possible credential.
- Logs: `release_ios/reader-ports/resume-20261103/`. Builds/tests and the
  existing cloud run are separate evidence, and local safety-tool changes are
  not present in that already-running cloud candidate.

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

## Downloaded Cloud Results: 41627388664

The existing candidate finished successfully; `publish` was skipped. All five
artifact groups are downloaded under `release_ios/41627388664/`. The original
Release 178 is not replaced. Downloaded acceptance log shows **333 actual iOS
integration tests passed**, with native bridge/JavaScriptCore jobs successful.
The live previous-source report remains **16 passed / 1 failed** (Miaoqu403),
with the already authorized narrow release policy; no new-source exemption.

Actual iOS anonymous metadata was independently revalidated with the stricter
local collector: WNACG discover20/search24, JM80/80 and public E-Hentai62/25.
All three use production WebKit/Dio HTTPS. Picacomic is `blocked_account` with
zero requests. This is not a real account or image-reading pass.

All **73 PNGs** (56 original tour, 11 live Copy, 6 port fixtures) match their
manifest names/size/dimensions/SHA-256 and were actually read via contact sheets.
Three H.264 videos fully decode locally: original tour **2085 frames/623.05s**,
Copy **681/631.398333s**, port fixtures **542/589.818333s**, all1206x2622.
This is full decoder verification, not full human viewing of the recordings.

The sixth-state fixture tour has a visual caveat: the JM screenshot shows
strip-permuted geometry because the adapter supplied the already-clear PNG to
the production restorer. This is a **test fixture defect**, not proof of a
production image-restoration defect (independent remainder/pixel unit tests
pass). A new canonical-RGBA assertion fails on that harness, then passes after
feeding JM the inverse-permuted synthetic PNG at the adapter seam. Four-source
download/save/offline plus production UI and JM restoration tests: **12 passed**.
No production rule/transport code changed. The corrected fixture and stronger
pixel assertion are local only; **no corrected iOS screenshot is claimed**.

After the fixture repair, the full serial Flutter suite was run again:
**1926 passed / 4 skipped**, 530 seconds. Final analyzer has no issues (9.4s),
after correcting import ordering. The earlier 504-second full run and the
12-test targeted run are separate evidence, not combined counts. Local fixes
touch tests/tools/workflow/docs only; production code and source rules are
unchanged from the cloud candidate. Copy's search capture still has thumbnail
placeholders, while its subsequent real reader images are visible; no claim
of every remote cover loading is made.

Unsigned IPA: `triomi-ios-unsigned/Triomi-iOS-Unsigned.ipa`, **13811237 bytes**,
SHA-256 **309a7fec28a825c885a4f98d594e84c3cca18be7518071f627c9572a1dfcb6bc**.
ZIP/Info.plist check:0.12.0+178, iOS15+, `io.github.hyperionhxh.triomi`.
All four rule files match exact candidate Git blobs; local Windows CRLF hashes
are different and are not used as the candidate comparison. Generic payload
private-key markers/forbidden credential filenames find no matches; not a full
credential audit. Reports:`reader-ports-verification.json`,
`tour-ipa-verification.json`, `copy-verification.json`, `ipa-rule-safety.json`.
It is an Actions candidate, not a new published Release or device installation.

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
- [ ] Explicit safe sample reading/download/save acceptance; no arbitrary
  gallery images and no real Picacomic account gate this round.
- [x] Full local regression and platform builds (fresh resume results above).
- [x] Exact-candidate iOS contracts, metadata, artifact download/hash/media
  checks and actual screenshot inspection; JM fixture caveat retained above.
- [ ] Corrected synthetic JM fixture on actual iOS (requires a new explicitly
  authorized commit/push/run; no automatic commit in this session).
