# [3] Local / no-PR diff — a bare branch reviewed with no GitHub remote. Step 0
# resolves kind=branch (never pr), which is the deterministic precondition that
# makes review angle (d) "prior PRs" self-skip ("skipped: no PR context") while
# angles a/b/c/e still run.
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$FX_DIR/../_lib.sh"
fx_init main
git -C "$REPO" checkout -q -b feature
cat > "$REPO/app.go" <<'EOF'
package app

// Double returns twice n.
func Double(n int) int {
	return n + n
}
EOF
fx_commit "add Double on feature"
git -C "$REPO" checkout -q main
# deliberately no `git remote add` -> there is no PR context to use
TARGET="feature"
