# 0006: OS 27 model adaptation and ownership

Status: accepted, 2026-11-02. Implements M1-PR-06 without changing Core's model seam.

The installed Xcode 27.2 SDK declares `LanguageModel` and `LanguageModelExecutor`
on iOS/macOS 27, with generic session initializers taking a model, tools and either
instructions or a transcript. The protocol exposes capabilities and executor
configuration, but no generic token-count, context-size or unload method. The
executor receives the model and a generation channel; its configuration is Hashable.
These facts were read from the installed SDK interface before implementation.

`LanguageModelProvider<Model>` is an availability-gated Providers adapter. It
requires an explicit network declaration and accepts caller-supplied window and
rendered-transcript token metadata. Common session mechanics are shared with the
system adapter, including fresh sessions, schema translation, nonexecuting capture
tools, typed refusals/overflow, bounded retries and streaming. Streaming is explicit
opt-in for the generic adapter because the executor channel supports text-segment
replacement, which an append-only runtime event cannot represent. Default final
responses preserve those backends' complete output. No Apple model types
enter Core or Runtime.

Copies share an immutable model holder through ARC. Construction creates no session;
prewarming is explicit. This does not establish lazy private-weight loading or forced
eviction: backends and any framework executor cache can own resources independently
of the adapter. Backend concurrency, cancellation and eviction remain explicit
responsibilities. M1-PR-04 stays partial; a generic unload API is not invented to
make its checkbox appear complete.

The asset-free fixture suite exercises Apple's real generic session pipeline on
an iOS 27 simulator. The macOS host is 26.6.2, where that suite is correctly gated
off. Existing system-model regression tests run on the real Mac model separately.
This is adapter evidence, not a custom model quality or memory benchmark.
