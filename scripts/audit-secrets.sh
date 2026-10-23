set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v gitleaks >/dev/null 2>&1; then
    echo 'Install Gitleaks before running the publication audit.' >&2
    exit 2
fi
cd "$project_root"
gitleaks git --redact=100 --no-banner --log-opts='--all --reflog' .
gitleaks dir --redact=100 --no-banner .
echo 'PASS: history and working-directory secret scans'
