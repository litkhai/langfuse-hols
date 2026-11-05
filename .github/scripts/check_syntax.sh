#!/usr/bin/env bash
# Parse-check every tracked shell, Python and YAML file.
# Run from the repository root:  ./.github/scripts/check_syntax.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
failed=0

echo "--- shell (bash -n)"
while IFS= read -r f; do
    if ! bash -n "$f" 2>/tmp/syntax_err; then
        echo "  FAIL $f"
        sed 's/^/        /' /tmp/syntax_err
        failed=1
    fi
done < <(git ls-files '*.sh')
echo "    $(git ls-files '*.sh' | wc -l | tr -d ' ') files"

echo "--- python (py_compile)"
while IFS= read -r f; do
    if ! python3 -m py_compile "$f" 2>/tmp/syntax_err; then
        echo "  FAIL $f"
        sed 's/^/        /' /tmp/syntax_err
        failed=1
    fi
done < <(git ls-files '*.py')
echo "    $(git ls-files '*.py' | wc -l | tr -d ' ') files"
find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

echo "--- yaml (safe_load; Compose merge tags !reset / !override accepted)"
yaml_check='
import sys, yaml
class L(yaml.SafeLoader): pass
def tag(loader, node):
    if isinstance(node, yaml.MappingNode): return loader.construct_mapping(node)
    if isinstance(node, yaml.SequenceNode): return loader.construct_sequence(node)
    return loader.construct_scalar(node)
for t in ("!reset", "!override"): L.add_constructor(t, tag)
list(yaml.load_all(open(sys.argv[1]), Loader=L))
'
while IFS= read -r f; do
    if ! python3 -c "$yaml_check" "$f" 2>/tmp/syntax_err; then
        echo "  FAIL $f"
        sed 's/^/        /' /tmp/syntax_err
        failed=1
    fi
done < <(git ls-files '*.yml' '*.yaml')
echo "    $(git ls-files '*.yml' '*.yaml' | wc -l | tr -d ' ') files"

rm -f /tmp/syntax_err
[ "$failed" -eq 0 ] && echo "OK: all files parse"
exit "$failed"
