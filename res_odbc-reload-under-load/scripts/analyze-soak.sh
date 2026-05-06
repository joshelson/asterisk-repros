#!/usr/bin/env bash
# Reads the RSS sampler log from the asterisk container and produces
# a compact summary: starting/ending RSS, peak, growth %, time series
# of RSS at 60-second intervals.
set -euo pipefail

LOG="${1:-}"
if [[ -z "$LOG" ]]; then
  # Default: pull from the asterisk container.
  LOG=/tmp/soak-rss.log
  docker compose exec -T asterisk cat /tmp/rss.log > "$LOG"
fi

awk '
NR == 1 {
  start_t = $1
  start_rss = $2
}
{
  t = $1
  rss = $2
  if (rss+0 > peak_rss) peak_rss = rss
  end_t = t
  end_rss = rss
  total++
}
END {
  duration = end_t - start_t
  growth = end_rss - start_rss
  growth_pct = start_rss ? 100.0 * growth / start_rss : 0.0
  printf "samples:      %d (every ~5 s)\n", total
  printf "duration:     %d s\n", duration
  printf "starting RSS: %d KB (%.1f MB)\n", start_rss, start_rss / 1024.0
  printf "ending   RSS: %d KB (%.1f MB)\n", end_rss, end_rss / 1024.0
  printf "peak     RSS: %d KB (%.1f MB)\n", peak_rss, peak_rss / 1024.0
  printf "growth:       %+d KB (%+.2f%%)\n", growth, growth_pct
}
' "$LOG"

echo
echo "RSS time series (every 60 s, KB):"
awk -v base=0 'NR == 1 { base = $1 }
                { t = $1 - base; if (t % 60 < 5 && !seen[int(t/60)]++) print int(t/60)*60 "s\t" $2 " KB" }
              ' "$LOG"
