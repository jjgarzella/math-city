# [2a] Empty diff — the default target on an unchanged branch resolves to an
# empty diff, which step 0 stops on deterministically (no model, no pipeline).
FX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$FX_DIR/../_lib.sh"
fx_init main
TARGET=""   # -> main..HEAD, and HEAD == main, so the diff is empty
