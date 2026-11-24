# M5-06 semantic loop detection verification

Verified 2026-11-24 with synthetic calls, mocked tools and model providers.

## Scope

`AgentConfiguration.loopDetection` accepts opt-in tool/argument text rules. Each rule
normalizes case and whitespace, and declared equivalent phrase groups merge transitively.
This detects known semantic repetition without guessing synonyms, invoking a model or
embedding provider, changing execution arguments, or weakening exact matching elsewhere.

Serial calls and whole batches share admission checks. The third equivalent consecutive
call stops before execution; equivalent alternating cycles also stop. Each run gets fresh
history. Existing loopDetected errors and failure events remain the public outcome.

Signatures now compare JSON structures, avoiding delimiter ambiguity. Integer-equivalent
doubles normalize safely without trapping on large finite values or infinities. Periods
are clamped to 1...64, bounding retained history to 129 signatures.

## Evidence

- Full and offline suites: 884 registered functions, all passed.
- LoopDetectorTests: 18 functions; SemanticLoopRuntimeTests: three functions. Twelve added
  functions cover known paraphrases, normalization, transitive/order-independent groups,
  distinct arguments/types/nesting, collision regression, huge numbers/periods, nested
  numeric equivalence, resets, serial rejection and whole-batch admission.
- Thread Sanitizer: 35 loop/runtime/parallel-tool functions passed with no reported races.
  The two additional deterministic equivalence/numeric functions passed in the final full suite.
- Warning-free Swift build, strict changed-file formatting, layering and whitespace checks passed.
- Core coverage: 99.80% (992/994); Runtime: 98.59% (2941/2983).
- Combined coverage: 98.89% (3933/3977), up 0.06 percentage points from M5-05.
  Core unchanged; Runtime up 0.08 points.
- Demo: 45 tests passed; generic iOS build succeeded with signing disabled.
- DocC build and static routes passed: six modules, 10,393 internal references.

## Limits

Semantic rules are application assertions, not a general natural-language similarity
classifier. Unknown paraphrases are not detected semantically. Punctuation, word order,
negation, numbers and unconfigured values are preserved unless the application explicitly
groups whole phrases. Do not configure case-sensitive identifiers or write payloads.

The detector does not analyze result changes or infer external progress. Intentional
polling with equivalent arguments can hit the existing threshold. Rule/argument size is
application-owned; the history count cap is not a byte-size limit. No native model-quality,
latency or energy claim is made. Expanded harness scenarios and M8 verification remain
M5-08/M5-09.
