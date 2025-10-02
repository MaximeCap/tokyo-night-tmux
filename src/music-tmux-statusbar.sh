#!/usr/bin/env bash -xv

# Imports
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
. "${ROOT_DIR}/lib/coreutils-compat.sh"

# Check the global value
SHOW_MUSIC=$(tmux show-option -gv @tokyo-night-tmux_show_music)

if [ "$SHOW_MUSIC" != "1" ]; then
  echo "Here"
  exit 0
fi

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source $CURRENT_DIR/themes.sh

ACCENT_COLOR="${THEME[blue]}"
SECONDARY_COLOR="${THEME[background]}"
BG_COLOR="${THEME[background]}"
BG_BAR="${THEME[background]}"
TIME_COLOR="${THEME[black]}"

if [[ $1 =~ ^[[:digit:]]+$ ]]; then
  MAX_TITLE_WIDTH=$1
else
  MAX_TITLE_WIDTH=$(($(tmux display -p '#{window_width}' 2>/dev/null || echo 120) - 90))
fi

# playerctl
if command -v playerctl >/dev/null; then
  PLAYER_STATUS=$(playerctl -a metadata --format "{{status}};{{mpris:length}};{{position}};{{title}}" | grep -m1 "Playing")
  STATUS="playing"

  # There is no playing media, check for paused media
  if [ -z "$PLAYER_STATUS" ]; then
    PLAYER_STATUS=$(playerctl -a metadata --format "{{status}};{{mpris:length}};{{position}};{{title}}" | grep -m1 "Paused")
    STATUS="paused"
  fi

  TITLE=$(echo "$PLAYER_STATUS" | cut -d';' --fields=4)
  DURATION=$(echo "$PLAYER_STATUS" | cut -d';' --fields=2)
  POSITION=$(echo "$PLAYER_STATUS" | cut -d';' --fields=3)

  # Convert position and duration to seconds from microseconds
  DURATION=$((DURATION / 1000000))
  POSITION=$((POSITION / 1000000))

  if [ "$DURATION" -eq 0 ]; then
    DURATION=-1
    POSITION=0
  fi

# media-control
elif command -v media-control >/dev/null; then
  # Get media info from media-control
  MEDIA_DATA=$(media-control get --now 2>/dev/null)

  if [ -n "$MEDIA_DATA" ]; then
    # Extract properties using jq
    TITLE=$(echo "$MEDIA_DATA" | jq -r '.title // empty' 2>/dev/null)
    PLAYBACK_RATE=$(echo "$MEDIA_DATA" | jq -r '.playbackRate // 0' 2>/dev/null)

    # Determine playback status based on playback rate
    # playbackRate > 0 means playing, 0 or paused means paused
    if [ -n "$PLAYBACK_RATE" ] && [ "$PLAYBACK_RATE" != "null" ]; then
      if (( $(echo "$PLAYBACK_RATE > 0" | bc -l 2>/dev/null || echo 0) )); then
        STATUS="playing"
      else
        STATUS="paused"
      fi
    else
      # Fallback: check if there's a playbackStatus field
      PLAYBACK_STATUS=$(echo "$MEDIA_DATA" | jq -r '.playbackStatus // empty' 2>/dev/null)
      if [ "$PLAYBACK_STATUS" = "playing" ]; then
        STATUS="playing"
      else
        STATUS="paused"
      fi
    fi

    # Get timeline information
    # media-control uses elapsedTime and duration (in seconds)
    RAW_DURATION=$(echo "$MEDIA_DATA" | jq -r '.duration // empty' 2>/dev/null)
    RAW_POSITION=$(echo "$MEDIA_DATA" | jq -r '.elapsedTimeNow // empty' 2>/dev/null)

    # Convert to integers (rounded)
    if [ -n "$RAW_DURATION" ] && [ "$RAW_DURATION" != "null" ]; then
      DURATION=$(printf "%.0f" "$RAW_DURATION" 2>/dev/null || echo "-1")
    else
      DURATION=-1
    fi

    if [ -n "$RAW_POSITION" ] && [ "$RAW_POSITION" != "null" ]; then
      POSITION=$(printf "%.0f" "$RAW_POSITION" 2>/dev/null || echo "0")
    else
      POSITION=0
    fi

    # macOS fix for paused position (media-control bug workaround)
    if [[ $OSTYPE == "darwin"* ]]; then
      if [ "$STATUS" = "playing" ] && [ "$POSITION" -gt 0 ]; then
        echo "$POSITION" >/tmp/media_control_last_position 2>/dev/null
      fi

      if [ "$STATUS" = "paused" ] && [ -f /tmp/media_control_last_position ]; then
        SAVED_POSITION=$(cat /tmp/media_control_last_position 2>/dev/null)
        if [ -n "$SAVED_POSITION" ] && [ "$SAVED_POSITION" != "0" ]; then
          POSITION=$SAVED_POSITION
        fi
      fi
    fi
  fi
fi

# Calculate the progress bar for sane durations
if [ -n "$DURATION" ] && [ -n "$POSITION" ] && [ "$DURATION" -gt 0 ] && [ "$DURATION" -lt 3600 ]; then
  # Try gdate first (macOS with GNU coreutils), fallback to date
  if command -v gdate >/dev/null 2>&1; then
    TIME="[$(gdate -d@$POSITION -u +%M:%S) / $(gdate -d@$DURATION -u +%M:%S)]"
  else
    TIME="[$(date -d@$POSITION -u +%M:%S 2>/dev/null || date -r $POSITION -u +%M:%S) / $(date -d@$DURATION -u +%M:%S 2>/dev/null || date -r $DURATION -u +%M:%S)]"
  fi
else
  TIME="[--:--]"
fi

if [ -n "$TITLE" ]; then
  if [ "$STATUS" = "playing" ]; then
    PLAY_STATE="░ "
  else
    PLAY_STATE="░ 󰏤"
  fi
  OUTPUT="$PLAY_STATE $TITLE"

  # Only show the song title if we are over $MAX_TITLE_WIDTH characters
  if [ "${#OUTPUT}" -ge $MAX_TITLE_WIDTH ]; then
    OUTPUT="$PLAY_STATE ${TITLE:0:$MAX_TITLE_WIDTH-1}…"
  fi
else
  OUTPUT='not working'
fi

MAX_TITLE_WIDTH=25
if [ "${#OUTPUT}" -ge $MAX_TITLE_WIDTH ]; then
  OUTPUT="$PLAY_STATE ${TITLE:0:$MAX_TITLE_WIDTH-1}"
  # Remove trailing spaces
  OUTPUT="${OUTPUT%"${OUTPUT##*[![:space:]]}"}…"
fi

if [ -z "$OUTPUT" ]; then
  echo "$OUTPUT #[fg=green,bg=default]"
else
  OUT="$OUTPUT $TIME "
  ONLY_OUT="$OUTPUT "
  TIME_INDEX=${#ONLY_OUT}
  OUTPUT_LENGTH=${#OUT}

  # Protect against division by zero
  if [ "$DURATION" -gt 0 ]; then
    PERCENT=$((POSITION * 100 / DURATION))
    PROGRESS=$((OUTPUT_LENGTH * PERCENT / 100))
  else
    PERCENT=0
    PROGRESS=0
  fi

  O="$OUTPUT"

  if [ $PROGRESS -le $TIME_INDEX ]; then
    echo "#[nobold,fg=$BG_COLOR,bg=$ACCENT_COLOR]${O:0:PROGRESS}#[fg=$ACCENT_COLOR,bg=$BG_BAR]${O:PROGRESS:TIME_INDEX} #[fg=$TIME_COLOR,bg=$BG_BAR]$TIME "
  else
    DIFF=$((PROGRESS - TIME_INDEX))
    echo "#[nobold,fg=$BG_COLOR,bg=$ACCENT_COLOR]${O:0:TIME_INDEX} #[fg=$BG_BAR,bg=$ACCENT_COLOR]${OUT:TIME_INDEX:DIFF}#[fg=$TIME_COLOR,bg=$BG_BAR]${OUT:PROGRESS}"
  fi
fi
