# shellcheck shell=bash disable=SC2034 # Sourced; the arrays are read by setup.
# Model/thinking ladder, sourced by omp-profile-setup.sh. Each entry is a
# Cursor model id with its own startup thinking level.
# Setup persists the chosen pair as "<id>:<level>"; the engine reads the level
# back from that suffix, never from this ladder. Cursor no longer supports
# Gemini, so the ladder is the single plain grok-4.7 at high (not the -fast or
# -500k variants).
MODEL_LADDER=(cursor/grok-4.7)
THINKING_LADDER=(high)
