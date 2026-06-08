# [4] The canonical dedup case (from the .4 handoff): a RESURRECTED bug. A prior
# commit added a load-bearing empty-slice guard on purpose; the change under
# review drops it. The shallow bug scan (angle b) and the git-history angle (c)
# both flag the SAME file + line + root cause, so step 7 must merge them into
# ONE promoted bead citing both angles.
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$FX_DIR/../_lib.sh"
fx_init main
# v1: First WITH the guard (the edge case a prior commit added deliberately).
cat > "$REPO/app.go" <<'EOF'
package app

// First returns the first element, or -1 for an empty slice.
func First(xs []int) int {
	if len(xs) == 0 {
		return -1
	}
	return xs[0]
}
EOF
fx_commit "add First with an empty-slice guard"
# The change under review RESURRECTS the panic by deleting the guard.
cat > "$REPO/app.go" <<'EOF'
package app

// First returns the first element.
func First(xs []int) int {
	return xs[0]
}
EOF
fx_commit "simplify First (drops the empty-slice guard)"
TARGET="HEAD~1..HEAD"
