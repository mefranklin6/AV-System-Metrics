#!/usr/bin/env bash
# Shared by update.sh and maintenance.sh. Source this file; it has no side effects.

record_lifecycle_event() {
  local metric_name="$1"
  local event_time="${2:-}"
  # Use psql variables through stdin so values are quoted as SQL literals.
  # The synthetic loopback source identifies a local administrative event.
  docker compose exec -T -e 'PGOPTIONS=-c lock_timeout=10s -c statement_timeout=30s' \
    postgres psql -X -U metrics_user -d metrics -v ON_ERROR_STOP=1 \
    -v lifecycle_metric="$metric_name" -v lifecycle_timestamp="$event_time" <<'SQL'
WITH event AS (
    SELECT COALESCE(NULLIF(:'lifecycle_timestamp', '')::timestamptz, clock_timestamp()) AS event_timestamp,
           clock_timestamp() AS received_at, gen_random_uuid() AS event_id
)
INSERT INTO public.metric_events
    (clientname, sort_key, event_timestamp, metric, action, event_id, received_at, source_ip)
SELECT 'AVSM-System',
       to_char(event_timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '000Z#' || event_id::text,
       event_timestamp, :'lifecycle_metric', 'Trace', event_id, received_at, '127.0.0.1'::inet
FROM event;
SQL
}

lifecycle_outcome() {
  case "$1" in
    0) printf 'completed' ;;
    129|130|143) printf 'interrupted (exit %s)' "$1" ;;
    *) printf 'failed (exit %s)' "$1" ;;
  esac
}
