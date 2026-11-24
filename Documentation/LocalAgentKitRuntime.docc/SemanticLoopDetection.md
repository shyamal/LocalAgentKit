# Detect equivalent repeated requests

Exact loop detection remains enabled for every run. Use Core's
`LoopDetectionConfiguration` through `AgentConfiguration.loopDetection` to declare
additional equivalences for selected top-level string arguments:

```swift
let loops = LoopDetectionConfiguration(textRules: [
  .init(tool: "search_documents", argument: "query", equivalentPhrases: [
    ["budget review notes", "notes for the budget meeting"]
  ])
])
let configuration = AgentConfiguration(model: model, loopDetection: loops)
```

Each rule normalizes case and whitespace for its named argument. Within a phrase group,
the application asserts that the phrases mean the same query. Overlapping groups merge
transitively, including across multiple rules for the same argument. No synonyms,
translations, punctuation removal or general paraphrase inference are performed.
Only declare equivalence when it is correct for that tool. Leave case-sensitive IDs,
write content, amounts and other exact values unconfigured. A changed unconfigured
argument, such as a pagination cursor, still distinguishes requests. Nested strings and
array order remain exact. Integer and exactly equivalent double values compare equally.

The detector compares argument structures, avoiding ambiguity from text delimiters.
It does not alter arguments sent to tools or retain results. There is no model call,
embedding, network request, or additional prompt content. It cannot infer progress
from changing external data; repeated intentional polling needs a different tool-call
contract. Unknown paraphrases still rely on the run's ordinary step and tool-call limits.

One retry is allowed: period-one repetition stops on the third equivalent call.
Alternating patterns stop at A, B, A, B, A. The default checks periods through three;
standalone ``LoopDetector`` accepts a maximum period clamped to 1...64, retaining at
most 129 signatures. Semantic rules are compiled once per run and history resets for
new runs. Rule and argument size remain application-owned; this is not an input-size limit.

Runtime admission checks serial calls before execution and all batch members before any
batch work. A match terminates with the existing `AgentError.loopDetected` and failure
event. Permission gates, run budgets, deadlines and cancellation retain their behavior.
The batch threshold counts proposed members, including equivalent members in one batch.
