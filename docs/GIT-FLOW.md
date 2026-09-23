# Git Flow

How work moves from `main` to a published release, and how a release gets fixed.

## Branches

| Branch | Cut from | Merges into | Holds |
|---|---|---|---|
| `main` | | | day-to-day work |
| `release/<version>` | `main`, or the previous release tag for a hotfix | `main`, once stable | the release candidate and its fixes |
| `fix/<desc>` | a `release/<version>` branch | that same release branch | one fix for that release |

`<version>` is the value of `VERSION` in `src/compiler/usage.ms`, without the `v`. Branch `release/0.2.54` ships tag `v0.2.54`.

## Rules

- A release branch takes fixes only. Features and refactors land on `main`.
- A fix for a release is cut from that release branch and merges back into it, never straight into `main`. It reaches `main` when the release merges back.
- The version tag is created on the release branch, never on `main`.
- A published tag never moves. A problem found after publishing ships as the next version.
- Release and fix branches each get their own worktree.

## 1. Cut the release branch

```bash
V=0.2.54
MAIN_TREE=$(git rev-parse --show-toplevel)
git branch release/$V main
git worktree add ../msc-release-$V release/$V
cd ../msc-release-$V
git submodule update --init --recursive
```

A fresh worktree lacks files the build needs but git does not track. Recreate them:

```bash
( cd vendor/mbedtls/tf-psa-crypto && python3 -m pip install --quiet jinja2 jsonschema && python3 scripts/generate_driver_wrappers.py core )
printf '#ifndef MINIZ_EXPORT_H\n#define MINIZ_EXPORT_H\n#define MINIZ_EXPORT\n#endif\n' > vendor/miniz/miniz_export.h
cp -R "$MAIN_TREE/examples" .
```

Check the version. If it does not read `$V`, the first commit on the branch sets it:

```bash
grep 'export const VERSION' src/compiler/usage.ms
git commit -m "chore(release): set the version to $V" -- src/compiler/usage.ms
```

Then bump `main` to the next version, so a binary built from `main` never reports the release number.

## 2. Stabilize

Push the branch; CI runs on every push to `release/**`.

```bash
git push -u origin release/$V
```

Run the local gates inside the release worktree:

```bash
msc build src/index.ms --gc=drc --danger --output=msc
msc test src/index.ms
msc run src/test/corpus/run.ms
MSCORPUS_SAN=1 msc run src/test/corpus/run.ms
msc run src/test/guard/run.ms --target=raiser
```

Then check the self-host fixpoint on emitted C. `tools/gate.sh --release` does not run it. Binaries are not reproducible, so compare the `.c` files:

```bash
./msc build src/index.ms --gc=drc --danger --cc=clang --output=/tmp/fx/gen1
cp out/release/.cache/*.c /tmp/fx/A/
/tmp/fx/gen1 build src/index.ms --gc=drc --danger --cc=clang --output=/tmp/fx/gen2
cp out/release/.cache/*.c /tmp/fx/B/
```

Cache file names end in a fingerprint (`<module>_x_ms.<hex>_<hex>.c`) that changes with the building compiler. `diff -rq A B` therefore reports every file. Pair the files by the name before the fingerprint and compare their contents. On 2026-09-19, 322 of 322 modules were identical while `gen1` and `gen2` differed as binaries. A side with 0 files means the wrong cache directory was copied: `--danger` and `--release` write `out/release/.cache`, a plain build writes `out/debug/.cache`.

Never run `tools/sync-local-binary.sh` from a worktree whose `vendor/` is incomplete: it mirrors `vendor/` into `~/.metascript/` with `--delete`.

## 3. Fix a release

```bash
git branch fix/<desc> release/$V
git worktree add ../msc-fix-<desc> fix/<desc>
cd ../msc-fix-<desc>
```

Commit the fix together with the test that pins it, push the branch, and open a pull request against `release/$V` so CI runs on it:

```bash
git push -u origin fix/<desc>
gh pr create --base release/$V --head fix/<desc>
```

Merge it into the release branch with a merge commit, then remove the fix worktree:

```bash
cd ../msc-release-$V
git merge --no-ff fix/<desc> -m "fix(release): merge fix/<desc> into release/$V"
git push origin release/$V
git worktree remove ../msc-fix-<desc>
git branch -d fix/<desc>
```

## 4. Tag and publish

Push the tag before running the release script. `tools/release.sh --upload` calls `gh release create v<VERSION>`, and when that tag does not exist on GitHub yet, `gh` creates it on the tip of `main` instead of the release branch.

```bash
cd ../msc-release-$V
git tag -a v$V -m "MetaScript v$V"
git push origin v$V
./tools/release.sh --upload
```

The script builds every target from the worktree it runs in, with the `msc` on `PATH`, and publishes a pre-release. It needs `msc`, `zig`, `zip`, `gh`, and GNU tar on macOS. When the release carries a compiler fix the installed `msc` lacks, put the fixed binary first on `PATH` (`mkdir relbin && cp msc relbin/msc && PATH=$PWD/relbin:$PATH ./tools/release.sh --upload`). Test the published archives, then promote:

```bash
gh release edit v$V --latest=true --prerelease=false
```

CI bootstraps from the release marked Latest, so promote only a release that can build the current `main`.

## 5. Merge the release back into main

Merge in a private worktree, then move `main` with a compare-and-swap, so a concurrent commit on `main` makes the land fail instead of being overwritten.

```bash
OLD=$(git rev-parse main)
git worktree add --detach ../msc-merge-$V "$OLD"
cd ../msc-merge-$V
git merge --no-ff release/$V -m "chore(release): merge release/$V into main"
NEW=$(git rev-parse HEAD)
cd "$MAIN_TREE"
git update-ref refs/heads/main "$NEW" "$OLD"
git worktree remove ../msc-merge-$V
```

On a conflict in `src/compiler/usage.ms`, keep the version from `main`.

Moving `main` does not touch the main working tree's files or index. Bring over each path the merge changed, but only where the main working tree has no local change to it:

```bash
git diff --name-only "$OLD" "$NEW" | while IFS= read -r p; do
  if ! git diff --quiet "$OLD" -- "$p" || ! git diff --cached --quiet "$OLD" -- "$p"; then
    echo "local changes, fold in by hand: git diff $OLD $NEW -- $p"
    continue
  fi
  entry=$(git ls-tree "$NEW" -- "$p")
  if [ -z "$entry" ]; then
    rm -f "$p"
    git update-index --force-remove -- "$p"
    continue
  fi
  mode=$(echo "$entry" | awk '{print $1}')
  sha=$(echo "$entry" | awk '{print $3}')
  [ "$mode" = 160000 ] && { echo "submodule, update by hand: $p"; continue; }
  mkdir -p "$(dirname "$p")"
  git cat-file blob "$sha" > "$p"
  [ "$mode" = 100755 ] && chmod +x "$p"
  git update-index --add --cacheinfo "$mode,$sha,$p"
done
```

A path reported as having local changes belongs to work in progress, and its index entry still holds the pre-merge version. Whoever commits that file next must first apply the printed `git diff` on top of their change; committing it as-is reverts the release's fix to that file.

When the merge has landed, remove the release worktree. The branch stays; the tag is the permanent pointer to what shipped.

```bash
git worktree remove ../msc-release-$V
```

## Hotfix when main is not releasable

Cut the next release branch from the last published tag instead of `main`, and follow the same steps:

```bash
git branch release/0.2.55 v0.2.54
```
