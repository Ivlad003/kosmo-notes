---
name: swift-module-cache-after-dir-rename
description: Swift's per-target ModuleCache hard-codes the absolute path it was created at; renaming or moving the project directory leaves stale .pcm files that cause "missing required module 'SwiftShims'" build failures
triggers:
  - "missing required module 'SwiftShims'"
  - "precompiled file '.../SwiftShims-"
  - "compiled with module cache path '"
  - SwiftShims pcm
  - swift build fails after directory rename
  - swift build fails after moving project
  - .build path mismatch
  - jarvis-studio kosmo-notes
  - ModuleCache stale path
---

# Swift ModuleCache Survives Directory Renames as a Time Bomb

## The Insight

`swift build` and Xcode bake the **absolute path** of the project directory into every `.pcm` file in `.build/<arch>/debug/ModuleCache/<hash>/`. The cache key is hash-based but the precompiled content references its origin path verbatim. If the project directory is renamed or moved while `.build/` still exists, every subsequent `swift build` reads a `.pcm` whose internal "I was built at /old/path" doesn't match where it now lives — and Swift's parser flags it as a missing module rather than a path mismatch in many cases.

The error message is misleading: it says **`missing required module 'SwiftShims'`** even though SwiftShims itself is fine — the failure is "I can't trust this precompiled module because its provenance metadata doesn't match my current location."

This codebase was renamed `jarvis-studio` → `kosmo-notes` mid-development; any contributor whose `.build/` survived the rename will hit this on their first `swift build` after pulling.

## Why This Matters

Without recognizing this, the chain of guesses goes wrong fast:
- "SwiftShims is missing — is my Xcode broken?" → reinstall Xcode (45 min wasted)
- "Maybe DEVELOPER_DIR is set wrong?" → fiddle with toolchain selection (no effect)
- "Maybe my Package.swift is corrupt?" → bisect commits looking for a recent change (won't find one)

The actual fix is one command, but only obvious if you've seen the failure mode before. The error mentions a specific stale path (`/Users/.../jarvis-studio/.build/...`) inside the diagnostic — that path is the only signal pointing at the real cause. Don't ignore it just because the headline says "missing module".

## Recognition Pattern

The signature is **a path string in the error that doesn't match `pwd`**. Look for:

```
precompiled file '/Users/<you>/.../<OLD-DIR-NAME>/.build/.../ModuleCache/<hash>/SwiftShims-<hash>.pcm'
  was compiled with module cache path '/Users/<you>/.../<OLD-DIR-NAME>/.build/.../ModuleCache/<hash>',
  but the path is currently '/Users/<you>/.../<NEW-DIR-NAME>/.build/.../ModuleCache/<hash>'
missing required module 'SwiftShims'
```

If the two paths differ only in one component (e.g. `jarvis-studio` vs `kosmo-notes`, or `MyApp` vs `MyApp-old`), it's this bug. The hashes match — Swift IS finding the cache file; it just refuses to use it because the path moved.

## The Approach

**Don't reach for the heavy hammer.** Don't reinstall Xcode, don't `rm -rf ~/Library/Developer/Xcode/DerivedData`, don't bisect. The fix is targeted:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift package clean
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

`swift package clean` blows away `.build/` entirely, including the stale `ModuleCache/`. The next build is slower (~16 s here vs the usual ~1 s incremental) but emits fresh `.pcm`s with the current path baked in.

**Decision-making heuristic:** When a Swift build error contains an absolute path, *always* check whether that path matches your current working directory. If it doesn't, suspect cache staleness before suspecting code or toolchain. Same applies to xcodebuild's DerivedData — moving an Xcode project triggers analogous failures, fixable by deleting the project's DerivedData folder (not all of DerivedData).

## Prevention

- Don't rename the project directory while `.build/` exists; clean first, then rename.
- After pulling a commit that renames repo subdirs, eyeball whether `.build/` should be cleaned (any path-shaped change).
- For CI, this never happens because each runner starts with no `.build/` cache.

## Related

`tcc-adhoc-signing-cycle-expertise` covers a similar shape: paths/identities baked into a binary that don't survive a rebuild. Different domain (TCC permissions), same lesson — macOS toolchain bakes in stable identifiers that aren't stable across the operations a developer routinely performs.
