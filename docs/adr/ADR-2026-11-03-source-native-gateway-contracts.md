# Source-Scoped Native Gateway Contracts

Status: accepted for host 0.12.0+179.

## Context

Installing JavaScript rules does not add binary image transforms, secure account
storage or a signing gateway to an older application. Official iOS178 lacks the
JM/Pica adapters present in the later candidate67ce2cd, despite sharing a version
label. A rule catalog must not imply that JSON installation supplies native code.

## Decision

Ship the existing restricted adapters in host179 and declare native contracts in
both rule JSON and catalog entries using `requiresHost`:

```json
{"requiresHost": ["jmcomic.api.v1", "jmcomic.image.v1"]}
```

The Pica contract is `picacomic.account.v1`. The compiled supported set is owned
by the application, not the downloaded rule. Unknown contracts prevent install,
manual import and enabled script loading. Catalog UI explains missing support.
The downloaded rule cannot hide a contract absent from its catalog entry.
Pre-declaration JM/Pica identities retain implicit native dependencies.

The declaration grants no privileges. Production factories still choose adapters
by source identity, and native clients validate official HTTPS origins, paths,
methods and read-only operations. Account login is a separate application UI;
passwords/session tokens never enter JavaScript. JM image restoration remains in
the shared production image loading/download/save path. No arbitrary native
method bridge, binary script download or proxy server is introduced.

## Consequences

- Users update the application once to obtain these native implementations;
  later metadata/parser changes can be delivered as JSON rules.
- Changes to signing, encryption or image contracts may still need an app update.
- Old applications ignore unknown fields; warnings remain necessary in their
  catalog entries. This protocol cannot retroactively enforce old-host behavior.
- New native contract IDs require implementation and isolated regression tests;
  merely adding an ID to JSON never implements a new source gateway.
- Synthetic account/image tests and native iOS execution are distinct from real
  user account login and live upstream image acceptance.
