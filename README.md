# bazel-fork-to-patch

Migrate local/forked Bazel rules back to official upstream using bzlmod patches.

## Problem

During the WORKSPACE era, many teams copied official Bazel rulesets locally (e.g., `rules_apple`, `rules_swift`, `rules_ios`) to apply custom fixes, Bazel version compatibility patches, or business-specific logic. With WORKSPACE disabled by default in Bazel 8 and removed in Bazel 9, these local copies need to be replaced with official `bazel_dep` + `single_version_override` patches in `MODULE.bazel`.

The official Bazel migration guide covers replacing `http_archive`/`git_repository` with `bazel_dep`, but doesn't specifically address the workflow for locally modified copies: diffing against upstream, generating patch files, and wiring up bzlmod overrides.

This skill fills that gap.

## What's included

```
bazel-fork-to-patch/
├── SKILL.md              # Four-phase migration workflow
└── scripts/
    └── diff_rules.sh     # Automated diff & patch generation tool
```

## Workflow

1. **Discover** — Identify the official upstream repo for your local rules
2. **Diff** — Compare local copy vs. official upstream at a target version
3. **Patch** — Generate `.patch` files in bzlmod-compatible format (`patch_strip = 1`)
4. **Integrate** — Wire up `MODULE.bazel` with `bazel_dep` + override + patches

## Quick start

```bash
bash scripts/diff_rules.sh \
  --local /path/to/your/local/rules \
  --upstream https://github.com/bazelbuild/rules_apple \
  --upstream-tag 3.5.0 \
  --output-dir ./patches
```

## References

- [Bzlmod Migration Guide (official)](https://bazel.build/external/migration)
- [Bzlmod Migration Tool](https://bazel.build/external/migration_tool)
- [MODULE.bazel overrides reference](https://bazel.build/rules/lib/globals/module)
- [EngFlow: Fixing and Patching Breakages](https://blog.engflow.com/2025/03/25/migrating-to-bazel-modules-aka-bzlmod---fixing-and-patching-breakages/)
- [Bazel 8.0 release notes](https://blog.bazel.build/2024/12/09/bazel-8-release.html)
