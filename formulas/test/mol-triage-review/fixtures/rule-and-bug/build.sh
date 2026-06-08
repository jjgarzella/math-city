# [1] A diff that both violates a WRITTEN project rule AND introduces a real
# bug -> both should survive scoring and be promoted (two distinct findings,
# different root causes, so step 7 does NOT merge them).
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$FX_DIR/../_lib.sh"
fx_init main
# Plant the written rules first so they pre-exist the change under review.
cat > "$REPO/AGENTS.md" <<'EOF'
# Project rules

- Every exported function MUST have a doc comment.
- Never call os.Exit in library code; return an error instead.
EOF
fx_commit "add AGENTS.md project rules"
# The change under review:
#  - First: exported, NO doc comment (rule violation) AND indexes xs[0] with no
#    length check (real bug: panics on an empty slice).
cat > "$REPO/app.go" <<'EOF'
package app

func First(xs []int) int {
	return xs[0]
}
EOF
fx_commit "add First (missing doc comment + unguarded index)"
TARGET="HEAD~1..HEAD"
