#!/usr/bin/env bash
# 01-up.sh — bring the Langfuse self-hosted stack up (OSS mode) and wait until ready.
#
#   ./01-up.sh           # OSS stack (labs 01–04)
#   EE=1 ./01-up.sh      # same stack + enterprise overlay (labs 05–11; needs license key)
#                        # (labs 08 & 10 add their own overlays via their scripts)
#
# The stack is shared by every lab and lives in ../../../_base — this is a thin
# wrapper around _base/bin/up.sh v4 (see _base/README.md).
exec "$(dirname "${BASH_SOURCE[0]}")/../../../_base/bin/up.sh" v4 "$@"
