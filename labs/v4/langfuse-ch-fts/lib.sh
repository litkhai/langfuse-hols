# lib.sh — sourced by this lab's shell scripts. Not executed.
#
#   LAB_DIR      this directory
#   RUN_DIR      $LAB_DIR/.run (gitignored): measurement output of the last run
#   LAB_DB       lab_langfuse_ch_fts — the only database this lab creates, on both servers
#   FTS_CH       the lab's own ClickHouse container (newer than the stack's), started by 01-up.sh
#   FTS_IMAGE    its image tag; FTS_HTTP its HTTP port on 127.0.0.1
#   lf_ch  SQL   query the shared stack's ClickHouse (Langfuse's own server, HTTP 8123)
#   fts_ch SQL   query the lab's own ClickHouse
#
# The secrets file defaults to _base/.env of this clone; LF_ENV_FILE points at another clone's.
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LAB_DIR
. "$LAB_DIR/../../../_base/lib/env.sh" v4
LF_ENV_FILE="${LF_ENV_FILE:-$BASE_DIR/.env}"
load_env "$LF_ENV_FILE"
RUN_DIR="$LAB_DIR/.run"
LAB_DB=lab_langfuse_ch_fts
LAB_TAG=lab:langfuse-ch-fts
FTS_CH=lf-ch-fts-ch
FTS_IMAGE="${FTS_IMAGE:-26.10.10.3}"
FTS_HTTP="${FTS_HTTP:-38123}"
LF_CH_HTTP="${LF_CH_HTTP:-8123}"
export LAB_DB LAB_TAG FTS_HTTP LF_CH_HTTP

# lf_ch "SQL" [extra curl args] — stdin-free, one statement per call (HTTP interface)
lf_ch() {
  curl -fsS "http://127.0.0.1:$LF_CH_HTTP/" -u "$CLICKHOUSE_USER:$CLICKHOUSE_PASSWORD" --data-binary "$1" "${@:2}"
}
fts_ch() {
  curl -fsS "http://127.0.0.1:$FTS_HTTP/" -u "default:lab" --data-binary "$1" "${@:2}"
}

