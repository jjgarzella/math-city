# [5] A diff whose only "issues" fall on Anthropic's false-positive list, so
# scope discipline + the FP list must keep them ALL out: a formatting nitpick (a
# formatter/linter catches it) and missing test coverage (general code quality).
# There is no written rule and no real bug -> nothing is flagged.
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$FX_DIR/../_lib.sh"
fx_init main
cat > "$REPO/app.go" <<'EOF'
package app

import "fmt"

// Greet builds a greeting.  (No test added — general code-quality nitpick.)
func Greet(name string)  string {
	return fmt.Sprintf("hi %s", name)
}
EOF
fx_commit "add Greet (formatting + no test)"
TARGET="HEAD~1..HEAD"
