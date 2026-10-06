# env.sh — shared helpers for the workshop scripts (sourced, not executed). Pass the track:
#
#   . "<path>/_base/lib/env.sh" v4        # or v3; falls back to $LF_TRACK if no argument
#
#   BASE_DIR     absolute path of `_base/` (derived from this file, not from $PWD)
#   TRACK        v3 or v4: the first argument if it looks like a track (v<digits>) and
#                $BASE_DIR/<track>/versions.env exists, else $LF_TRACK under the same test,
#                else this file prints "env.sh: pass the track: v3 or v4" and returns 2
#   TRACK_DIR    $BASE_DIR/$TRACK  (versions.env, requirements.txt, seed_traces.py)
#   LF_TRACK     = $TRACK, exported (the compose project name reads it)
#   LF_PROJECT   langfuse-hols-$TRACK — the compose project; containers are
#                $LF_PROJECT-<service>-1, e.g. langfuse-hols-v4-clickhouse-1
#   load_env     robust .env loader (default file: $BASE_DIR/.env)
#   lf_compose   docker compose against the shared stack of that track:
#                  lf_compose [overlay ...] -- <compose args>
#                runs  docker compose --env-file $TRACK_DIR/versions.env
#                                     [--env-file ${LF_ENV_FILE:-$BASE_DIR/.env}]  (if it exists)
#                                     -f $BASE_DIR/docker-compose.yml
#                                     -f $BASE_DIR/docker-compose.<overlay>.yml ... <args>
#                e.g.  lf_compose ee masking -- up -d
#                The track pins come first, so a value in _base/.env (or in the shell) wins.
#                LF_ENV_FILE swaps the secrets file (check.sh --env-file). Passing any
#                --env-file stops compose from reading the default .env, so both are
#                passed explicitly. The base file is always first: compose resolves
#                relative paths from the directory of the FIRST -f file (= `_base/`),
#                so this works from any current directory.
#
# Usage from a lab script (labs/v4/<lab>/ is three levels below the repository root):
#   . "$(dirname "${BASH_SOURCE[0]}")/../../../_base/lib/env.sh" v4
#   load_env "$BASE_DIR/.env"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Track: $1 if it is a track, else $LF_TRACK, else refuse. When this file is sourced
# without an argument bash shows the caller's own $1 (e.g. `--purge`), so a candidate
# must match v<digits> AND have a versions.env before it is taken as a track.
TRACK=""
for _lf_cand in "${1:-}" "${LF_TRACK:-}"; do
  case "$_lf_cand" in
    v[0-9]*) [[ -f "$BASE_DIR/$_lf_cand/versions.env" ]] && { TRACK="$_lf_cand"; break; } ;;
  esac
done
unset _lf_cand
if [[ -z "$TRACK" ]]; then
  echo "env.sh: pass the track: v3 or v4" >&2
  return 2
fi
TRACK_DIR="$BASE_DIR/$TRACK"
export LF_TRACK="$TRACK"
LF_PROJECT="langfuse-hols-$TRACK"
export LF_PROJECT

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
  local -a envs=(--env-file "$TRACK_DIR/versions.env")
  local secrets="${LF_ENV_FILE:-$BASE_DIR/.env}"
  [[ -f "$secrets" ]] && envs+=(--env-file "$secrets")
  LF_TRACK="$TRACK" docker compose "${envs[@]}" "${files[@]}" "$@"
}
