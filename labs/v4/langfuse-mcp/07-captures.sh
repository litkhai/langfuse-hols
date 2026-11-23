#!/usr/bin/env bash
# 07-captures.sh — the interactive screenshots of the README: 07-tty-capture.py for each, then
# 07-render.mjs. Needs XTERM (the @xterm/xterm 5.5.0 package directory) and PLAYWRIGHT.
# Run after 04-questions.sh (it prepares the client directory and the MCP configs).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./lib.sh
: "${Q1:?run with the Q1..Q5 of 04-questions.sh exported, e.g. via: . <(sed -n "/^Q[1-5]=/p" 04-questions.sh); export Q1 Q2 Q3 Q4 Q5}"
client_dir
python3 07-tty-capture.py tty-q1-slowest-nohint clickhouse "$Q1"     # the first run accepts the folder-trust prompt
python3 07-tty-capture.py tty-q2-cost-users clickhouse "$Q2" &
HINT=1 python3 07-tty-capture.py tty-q1-slowest-hint clickhouse "$Q1" &
python3 07-tty-capture.py tty-q4-prompt-diff both "$Q4" &
wait
python3 07-tty-capture.py tty-q5-pii-clickhouse clickhouse "$Q5" &
python3 07-tty-capture.py tty-q5b-pii-langfuse langfuse "$Q5" &
wait
node 07-render.mjs tty-q1-slowest-nohint tty-q1-slowest-hint tty-q2-cost-users tty-q4-prompt-diff tty-q5-pii-clickhouse tty-q5b-pii-langfuse
