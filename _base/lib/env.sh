# _env.sh — robust .env loader shared by the workshop scripts.
# Sourced, not executed. Handles unquoted values WITH spaces (e.g.
# `LLM Observability`), inline `# comments`, surrounding quotes and CRLF —
# things a plain `. ./.env` chokes on. Matches how docker-compose reads .env.
load_env() {
  local f="${1:-.env}"
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
