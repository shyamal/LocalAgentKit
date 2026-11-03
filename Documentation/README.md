# Documentation build and publishing

M1-DC-01 adds six module catalogs, a merged package landing page, architecture
notes, and a GitHub Pages workflow. App Intents remains a placeholder and is
labelled as such. Generated symbol pages are not proof that every public API has
complete prose; the M1-DC-04 audit adds comments for the authored SDK surface and
a regression check. The guides' independent developer validation remains pending.

## Start using the SDK

[Build your first agent](LocalAgentKitRuntime.docc/BuildYourFirstAgent.md) walks
through the checked-in calculator example and the optional real-model path.
Newcomer timing validation remains pending (M1-DC-02).

[Write a custom tool](LocalAgentKitTools.docc/WriteACustomTool.md) includes a
temperature converter, runtime integration and standalone tests. Its 76 application
source lines are locally checked; independent developer validation remains pending.
The documentation workflow runs both guide executables with scripted providers
and the custom-tool tests, so example code is compiled alongside the catalogs.

The [independent developer validation procedure](../docs/developer-validation.md)
defines timing, code counting, evidence and a session report for both guides.
No independent session has been recorded yet.

## Build locally

Use macOS with Xcode 27 and its full SDK selected. Xcode 27.2 (27B52) was used for
local verification on 2026-10-31. Python 3 is the only script dependency. No DocC
package plugin or additional Swift dependency is added.

```bash
python3 Scripts/build-docs.py
python3 Scripts/check-docs.py .build/documentation/LocalAgentKit.doccarchive
```

The builder extracts public symbols with `swift package dump-symbol-graph`,
checks authored API comments, builds each implemented SDK library catalog with
warnings as errors, and merges
its archives with `docc merge`. Evaluation/dependency modules and the empty App
Intents target are excluded. Existing authored API comment warnings are fixed,
not filtered. Imported types use qualified code names where module-local symbol
links cannot resolve them. All generated files remain under ignored `.build/`.

A failed conversion leaves the previous archive intact. A successful build only
replaces an existing archive after checking its LocalAgentKit metadata. Source
catalogs and user files are never removed by the build. `check-docs.py` verifies
all six module routes and every internal topic-reference route; it does not
claim visual/browser verification or semantic correctness of API prose.

## Authored API documentation coverage

`Scripts/check-api-docs.py` runs inside the builder against fresh symbol graphs.
It requires a nonempty documentation comment for every source-authored public or
open symbol in Core, Runtime, Providers, Tools, SwiftUI and Testing, including
public extension members. It fails on absent primary graphs or modules with no
authored symbols, so missing inputs cannot produce a false pass. Duplicate symbol
identities across graphs count once.

The 2026-11-02 local audit covers 633 symbols: Core 282, Runtime 183, Providers 21,
Tools 67, SwiftUI 33 and Testing 47. Comments describe configuration, error and
event payloads, permissions, cancellation declarations, retrieval behavior,
storage limitations and test-double semantics. Source review also corrected the
audit signature's privacy description: argument signatures contain argument text,
and are not hashes or redacted values.

Compiler-synthesized symbols without source locations, imported framework APIs,
the empty AppIntents placeholder and internal evaluation-support/CLI targets are
outside this authored SDK-surface count. Inherited documentation can satisfy the
check when emitted by Swift. Nonempty comments alone do not establish correctness;
the strict DocC build checks links, and code review must check the described
behavior. API stability and release readiness are separate Milestone 6 work.

Run the checker tests without compiling Swift:

```bash
python3 -m unittest discover -s Scripts/tests -p 'test_api_docs.py'
```

The documentation workflow runs these tests and the same API gate. The hosted documentation build and API gate passed on 2026-11-02; artifact
upload initially failed on DocC filenames containing colons. PR #28 packaged
the archive and hosted run 41490218884 passed, including artifact upload. Live
publication remains unverified.

For a local HTTP preview without the GitHub project prefix:

```bash
python3 Scripts/build-docs.py --hosting-base-path '' --output .build/documentation-preview/LocalAgentKit.doccarchive
python3 -m http.server 8000 --directory .build/documentation-preview/LocalAgentKit.doccarchive
```

Open `http://localhost:8000/documentation/`. Stop the server with Ctrl-C.

## CI and Pages

`.github/workflows/documentation.yml` builds and validates on pull requests and
pushes to `main`; it also supports manual dispatch. Every build retains a
`LocalAgentKit-documentation` artifact containing `LocalAgentKit-documentation.tar.gz`.
The tar archive preserves DocC filenames containing colons and hidden files such
as `.nojekyll`, which must survive transport intact. After downloading and
unzipping the Actions artifact, extract it with:

```bash
tar -xzf LocalAgentKit-documentation.tar.gz
```

This produces `LocalAgentKit.doccarchive/`, suitable for local preview. The Pages
upload continues to use the original archive directory. No model assets, physical device, or
self-hosted evaluation runner is needed.

The build uses GitHub's documented hosted
[`xcode-27` image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md),
which carries the SDK types used by Providers. The installed actionlint 1.7.12
predates that label, so `.github/actionlint.yaml` adds it to its label allowlist.
Despite the linter setting's historical `self-hosted-runner` name, the requested
workflow image is hosted, not a persistent self-hosted runner.

Publishing requires the workflow to be merged into `main`, GitHub Pages to use
GitHub Actions as its publishing source, and the repository Actions variable
`LOCALAGENTKIT_DOCS_PUBLISH` set to `true`. The publish job alone receives
`pages: write` and `id-token: write`; PR jobs never publish. The process follows
[GitHub's custom Pages workflow guidance](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).
After deployment, the workflow runs `Scripts/check-published-docs.py` against the
URL returned by `deploy-pages`. It checks the package and six module HTML pages
plus their DocC JSON titles (14 routes), with bounded response size and per-request
timeouts. A missing page or HTML error response in place of render data fails the
publish job. This checks route/data availability; it does not execute the browser
JavaScript or prove every static asset and deep link renders correctly.

To check a published site manually, including its project prefix:

```bash
python3 Scripts/check-published-docs.py https://shyamal.github.io/LocalAgentKit/
```

That URL is the expected default location, not a claim that the site is live.
Local verification served the generated archive over HTTP and passed all 14
routes; seven network-free checker tests cover failure and URL handling.
No site or repository setting was changed by this work.

The default hosting prefix is `/LocalAgentKit`. For a custom domain or another
prefix, set `LOCALAGENTKIT_DOCS_BASE_PATH` (`/` for a domain root). The retained
static archive has a root redirect to `documentation/`, and includes the merged
DocC renderer and per-topic routes.

The Pages API returned 404 during the setup check. Site availability/configuration
is therefore not confirmed. Publication remains pending a real GitHub build and
deployment; the local artifact is the verified result. The branch is based on
PR #17's harness work, which was still open when this task started.


Local verification: the strict six-module build and repeat build passed, along
with all internal static-topic route checks (7,195 references in the final
archive), actionlint, Swift formatting/layering and the existing 444 Swift tests (also with socket networking denied).
Core coverage was 98.77% (483/489), Runtime 98.34% (1482/1507), combined 98.45%
(1965/1996). Compared with the preceding PR check's 98.55%, two fewer Runtime
lines were covered; source edits in this task changed comments only.
