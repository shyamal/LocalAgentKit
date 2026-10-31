# Documentation build and publishing

M1-DC-01 adds six module catalogs, a merged package landing page, architecture
notes, and a GitHub Pages workflow. App Intents remains a placeholder and is
labelled as such. Generated symbol pages are not proof that every public API has
complete prose; the guides and full API-comment audit remain M1-DC-02..04.

## Build locally

Use macOS with Xcode 27 and its full SDK selected. Xcode 27.2 (27B52) was used for
local verification on 2026-10-31. Python 3 is the only script dependency. No DocC
package plugin or additional Swift dependency is added.

```bash
python3 Scripts/build-docs.py
python3 Scripts/check-docs.py .build/documentation/LocalAgentKit.doccarchive
```

The builder extracts public symbols with `swift package dump-symbol-graph`,
builds each implemented SDK library catalog with warnings as errors, and merges
its archives with `docc merge`. Evaluation/dependency modules and the empty App
Intents target are excluded. Existing authored API comment warnings are fixed,
not filtered. Imported types use qualified code names where module-local symbol
links cannot resolve them. All generated files remain under ignored `.build/`.

A failed conversion leaves the previous archive intact. A successful build only
replaces an existing archive after checking its LocalAgentKit metadata. Source
catalogs and user files are never removed by the build. `check-docs.py` verifies
all six module routes and every internal topic-reference route; it does not
claim visual/browser verification or full API-comment coverage.

For a local HTTP preview without the GitHub project prefix:

```bash
python3 Scripts/build-docs.py --hosting-base-path '' --output .build/documentation-preview/LocalAgentKit.doccarchive
python3 -m http.server 8000 --directory .build/documentation-preview/LocalAgentKit.doccarchive
```

Open `http://localhost:8000/documentation/`. Stop the server with Ctrl-C.

## CI and Pages

`.github/workflows/documentation.yml` builds and validates on pull requests and
pushes to `main`; it also supports manual dispatch. Every build retains a
`LocalAgentKit-documentation` artifact. No model assets, physical device, or
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
