---
name: bazel-fork-to-patch
description: >
  Migrate local/forked Bazel rules back to official upstream using bzlmod patches. Trigger when
  user mentions: replacing local or forked rules_* with upstream + patches, diffing local Bazel
  rules against official, generating bzlmod .patch files, single_version_override or
  archive_override with patches, removing legacy WORKSPACE rules in favor of bazel_dep + patches,
  finding which official repo a local rule came from (rules_apple, rules_swift, rules_ios, etc.),
  Bazel cache paths for external rules, or eliminating forked rulesets. Trigger even without
  explicit "bzlmod" if user wants to reconcile local rules with upstream. Works for any Bazel
  ruleset — not limited to specific rules.
---

# Bazel Fork-to-Patch Migration Skill

Migrate local copies of Bazel rules back to official upstream, applying your customizations
as bzlmod patch files instead of maintaining a full fork.

## When to use

Your project has a local copy of some Bazel rules (e.g., copied from `rules_apple`,
`rules_swift`, `rules_ios`, or any `rules_*`). The copy has been modified over time —
Bazel version compatibility fixes, custom build logic, bug fixes. You want to switch to the
official upstream rules via `bazel_dep` and carry your changes as `.patch` files.

---

## Phase 1: Discover — identify the official upstream

Sometimes the user knows which official repo their local rules came from. Sometimes they
don't. Help them figure it out.

### If the user doesn't know the upstream

Check the local rules for clues:

```bash
LOCAL_RULES="/path/to/local/rules"

# Look for module name, repo name, or origin hints
grep -r "module(" "$LOCAL_RULES" --include="*.bazel" --include="*.bzl" -l
cat "$LOCAL_RULES/MODULE.bazel" 2>/dev/null
cat "$LOCAL_RULES/WORKSPACE" 2>/dev/null | head -20

# Check git remote if it has git history
cd "$LOCAL_RULES" && git remote -v 2>/dev/null

# Look for common rule identifiers in .bzl files
grep -rh "rules_apple\|rules_swift\|rules_ios\|apple_common\|swift_common" \
  "$LOCAL_RULES" --include="*.bzl" | head -10
```

Common official Bazel rule repos (all under `github.com/bazelbuild/`):

| Local rule pattern | Likely upstream |
|---|---|
| apple build rules, `ios_application`, `macos_application` | `bazelbuild/rules_apple` |
| Swift compilation, `swift_library`, `swift_binary` | `bazelbuild/rules_swift` |
| Apple bundling support, provisioning profiles | `bazelbuild/rules_apple` |
| ObjC/C++ rules for Apple | `bazelbuild/rules_apple` + `apple_support` |
| Xcode config, toolchains | `bazelbuild/apple_support` |
| Kotlin rules | `bazelbuild/rules_kotlin` |
| Java rules | `bazelbuild/rules_java` |
| Proto rules | `bazelbuild/rules_proto` |
| Go rules | `bazelbuild/rules_go` |

Search the Bazel Central Registry if unsure:
```bash
# Check if a module exists on BCR
curl -s "https://registry.bazel.build/modules/<module_name>" | head -5
```

### Determine the target upstream version

```bash
# Clone upstream
git clone <upstream_url> /tmp/upstream-rules
cd /tmp/upstream-rules

# List available versions
git tag -l | sort -V | tail -20

# Check BCR for published versions
curl -s "https://registry.bazel.build/modules/<module_name>/" 2>/dev/null
```

Pick the target version — usually the latest stable release that's >= whatever the
local copy was originally based on.

### Find the closest matching upstream tag

If you're unsure which version the local copy was based on:

```bash
cd /tmp/upstream-rules
for tag in $(git tag -l | sort -V | tail -10); do
  git checkout "$tag" 2>/dev/null
  DIFF_COUNT=$(diff -rq "$LOCAL_RULES" . --exclude=.git --exclude=.github | wc -l)
  echo "$tag: $DIFF_COUNT file differences"
done
```

The tag with the fewest differences is closest to the local copy's base.

### Check Bazel cache for resolved external repos

If the project already builds, resolved external repos live in the output base:

```bash
OUTPUT_BASE=$(bazel info output_base)
ls "$OUTPUT_BASE/external/" | grep rules_

# bzlmod repos (Bazel 6+) have version suffixes
ls "$OUTPUT_BASE/external/" | grep "+"
```

---

## Phase 2: Diff — compare local vs. upstream

### Generate the diff

```bash
cd /tmp/upstream-rules && git checkout <target_tag>

diff -ruN /tmp/upstream-rules "$LOCAL_RULES" \
  --exclude='.git' \
  --exclude='.github' \
  --exclude='*.md' \
  --exclude='LICENSE' \
  --exclude='CODEOWNERS' \
  > /tmp/full-diff.patch
```

### Analyze the diff

```bash
# Which files changed
diff -rq /tmp/upstream-rules "$LOCAL_RULES" --exclude=.git --exclude=.github

# Changes by directory
grep "^diff " /tmp/full-diff.patch | sed 's|.*/||' | sort | uniq -c | sort -rn

# Total scope
echo "Files changed: $(grep -c '^diff ' /tmp/full-diff.patch)"
echo "Lines changed: $(grep '^[+-]' /tmp/full-diff.patch | grep -v '^[+-][+-][+-]' | wc -l)"
```

### Classify changes

For each changed file, ask:

| Category | Action |
|----------|--------|
| Bazel compat fix that upstream's target version already has | **DROP** |
| Bazel compat fix that upstream still doesn't have | **KEEP as patch** |
| Custom business logic specific to your project | **KEEP as patch** |
| Naming/branding changes from an old fork | **DROP** — revert to upstream names |
| Files only in local, not in upstream | **EVALUATE** — new file patch or separate rule |

```bash
# Check if upstream's target version already has a fix
# Compare specific files one at a time
diff /tmp/upstream-rules/path/to/file.bzl "$LOCAL_RULES/path/to/file.bzl"
```

---

## Phase 3: Patch — generate bzlmod-compatible patches

### Patch format

Patches must be standard unified diff with `a/` and `b/` prefixes (used with `patch_strip = 1`):

```diff
--- a/apple/internal/some_rule.bzl
+++ b/apple/internal/some_rule.bzl
@@ -100,7 +100,7 @@
     existing_line
-    old_line
+    new_line
     existing_line
```

### Generate the patch

```bash
cd /tmp/upstream-rules && git checkout <target_tag>

# Full patch with correct path prefixes
diff -ruN /tmp/upstream-rules "$LOCAL_RULES" \
  --exclude='.git' --exclude='.github' --exclude='*.md' \
  --exclude='LICENSE' --exclude='CODEOWNERS' \
  | sed "s|/tmp/upstream-rules|a|g; s|$LOCAL_RULES|b|g" \
  > ./patches/rules_name.patch
```

### Split into logical patches (recommended)

Don't lump everything into one giant patch. Split by concern:

```bash
# Split the full diff per file
csplit -z -f /tmp/per-file/chunk_ -b "%03d.patch" \
  ./patches/rules_name.patch '/^diff /' '{*}'

# Then manually group related files into logical patches:
# - bazel_compat.patch  (Bazel version compatibility fixes)
# - custom_logic.patch  (your project-specific changes)
```

### Validate patches

```bash
cd /tmp/upstream-rules && git checkout <target_tag>

# Test each patch applies cleanly
for patch in ./patches/*.patch; do
  echo "Testing: $patch"
  git apply --check "$patch" && echo "  OK" || echo "  FAILED"
done
```

---

## Phase 4: Integrate — wire up MODULE.bazel

### Choose the override mechanism

| Mechanism | When to use |
|-----------|-------------|
| `single_version_override` | Module is on BCR, pin version + apply patches |
| `archive_override` | Point to a specific archive URL + patches |
| `git_override` | Point to a specific git commit + patches |

### single_version_override (most common)

```starlark
# MODULE.bazel

bazel_dep(name = "rules_apple", version = "3.5.0")

single_version_override(
    module_name = "rules_apple",
    version = "3.5.0",
    patches = [
        "//patches:rules_apple_bazel_compat.patch",
        "//patches:rules_apple_custom_logic.patch",
    ],
    patch_strip = 1,
)
```

### git_override (for rules not on BCR, or pinning a commit)

```starlark
bazel_dep(name = "rules_apple", version = "3.5.0")

git_override(
    module_name = "rules_apple",
    commit = "abc123...",
    remote = "https://github.com/bazelbuild/rules_apple.git",
    patches = ["//patches:rules_apple_custom.patch"],
    patch_strip = 1,
)
```

### archive_override

```starlark
bazel_dep(name = "rules_apple", version = "3.5.0")

archive_override(
    module_name = "rules_apple",
    urls = ["https://github.com/bazelbuild/rules_apple/releases/download/3.5.0/rules_apple.3.5.0.tar.gz"],
    patches = ["//patches:rules_apple_custom.patch"],
    patch_strip = 1,
)
```

### Remove the local copy and update references

```bash
# Find all load() and deps references to the old local rules
grep -rn "@old_rules_name\|//local/rules/path" \
  --include="*.bzl" --include="*.bazel" --include="BUILD" .

# Replace with official upstream references
find . -type f \( -name "*.bzl" -o -name "*.bazel" -o -name "BUILD" \) \
  -exec sed -i 's|@old_rules_name|@rules_apple|g' {} +

# Build and test
bazel build //...
bazel test //...
```

---

## Important notes

- **Overrides only work in the root module.** If your project is a dependency of others,
  patches won't propagate downstream. Contribute fixes upstream when possible.
- **Patch maintenance.** Every upstream version bump can break patches. Keep them minimal.
- **`override_repo` (Bazel 7.4+)** replaces repos from module extensions.
- **`inject_repo` (Bazel 7.4+)** adds new repos into an extension's scope when patching.
- **Test thoroughly.** Run full build + test suite after migration.

---

## Helper script

The `scripts/diff_rules.sh` script automates Phase 1-3. Read it with:
```
view scripts/diff_rules.sh
```

Usage:
```bash
bash scripts/diff_rules.sh \
  --local /path/to/your/local/rules \
  --upstream https://github.com/bazelbuild/rules_apple \
  --upstream-tag 3.5.0 \
  --output-dir ./patches
```
