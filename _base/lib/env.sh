# env.sh — shared helpers for the workshop scripts (sourced, not executed):
#
#   BASE_DIR     absolute path of `_base/` (derived from this file, not from $PWD)
#   load_env     robust .env loader (default file: $BASE_DIR/.env)
#   lf_compose   docker compose against the shared stack:
#                  lf_compose [overlay ...] -- <compose args>
#                runs  docker compose -f $BASE_DIR/docker-compose.yml
#                                     -f $BASE_DIR/docker-compose.<overlay>.yml ... <args>
#                e.g.  lf_compose ee masking -- up -d
#                The base file is always first: compose resolves relative paths and
#                reads `.env` from the directory of the FIRST -f file (= `_base/`),
#                so this works from any current directory.
#
# Usage from a lab script:
#   . "$(dirname "${BASH_SOURCE[0]}")/../../_base/lib/env.sh"
#   load_env "$BASE_DIR/.env"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# load_env — handles unquoted values WITH spaces (e.g. `LLM Observability`),
# inline `# comments`, surrounding quotes and CRLF — things a plain `. ./.env`
# chokes on. Matches how docker-compose reads .env.
load_env() {
  local f="${1:-$BASE_DIR/.env}"
  [[ -f "$f" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == [[:space:]]*\#* || "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    # strip an inline comment introduced by " #"
    case "$val" in *" #"*) val="${val%% #*}";; esac
    # trim surrounding whitespace
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    # strip a single layer of surrounding quotes
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}";;
      \'*\') val="${val#\'}"; val="${val%\'}";;
    esac
    export "$key=$val"
  done < "$f"
}

# lf_compose [overlay ...] -- <compose args>
lf_compose() {
  local -a files=(-f "$BASE_DIR/docker-compose.yml")
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    files+=(-f "$BASE_DIR/docker-compose.$1.yml")
    shift
  done
  if [[ "${1:-}" != "--" ]]; then
    echo "lf_compose: usage: lf_compose [overlay ...] -- <compose args>" >&2
    return 2
  fi
  shift
  docker compose "${files[@]}" "$@"
}
