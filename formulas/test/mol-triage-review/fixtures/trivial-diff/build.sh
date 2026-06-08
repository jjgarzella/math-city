# [2b] Trivial diff — a non-empty but whitespace-only change. Step 0 produces a
# real (non-empty) diff, so the SEMANTIC eligibility gate (step 1, a model) is
# what skips it. The .6 dogfood verifies the skip; here we only assert step 0
# hands the pipeline a non-empty range.
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$FX_DIR/../_lib.sh"
fx_init main
printf 'package app\n\n\n' > "$REPO/app.go"   # add blank lines only
fx_commit "whitespace only"
TARGET="HEAD~1..HEAD"
