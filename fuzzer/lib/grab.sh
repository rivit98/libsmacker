# Pull the crashes and hangs of remote campaigns into one local directory.
#
#   ./fuzz grab -o DIR IP...
#
# On each host every id* file under the remote campaign dir that sits in a
# crashes/ directory, plus 20 sampled hangs, is copied into a freshly emptied
# /tmp/crashes, then moved here with rsync --remove-source-files (the rsync-move
# alias, spelled out: aliases do not exist in scripts). Hosts are done one after
# another; one that fails is reported and does not stop the rest.
#
# rsync is pointed at the staging directory, never at /tmp/crashes/* - that glob
# is expanded by the remote shell into one argument per file, and a host with
# tens of thousands of them fails the transfer with "Argument list too long"
# before rsync starts.
#
# The remote campaign dir mirrors this campaign's layout under the remote root
# account: REMOTE_CAMPAIGN_DIR, default /root/fuzz/$PROJECT_NAME. Override it to
# grab from a campaign kept elsewhere on the hosts.

REMOTE_CAMPAIGN_DIR="${REMOTE_CAMPAIGN_DIR:-/root/fuzz/$PROJECT_NAME}"

USAGE="usage: $PROG grab -o DIR IP...

  -o DIR   where the artifacts go (created if missing)
  IP...    the hosts, each reached as root@IP over ssh

On each host, every id* file under \$REMOTE_CAMPAIGN_DIR ($REMOTE_CAMPAIGN_DIR)
in a crashes/ directory, and 20 hangs sampled at random, are copied into a
freshly emptied /tmp/crashes and then moved into DIR with
rsync --remove-source-files. DIR is flat: files from every host and instance
land side by side, so two instances that saved the same id: name keep only one.
A host that fails (unreachable, or no crashes or hangs yet) is reported and the
rest still run; the exit status is non-zero if any failed."
usage_guard "$@"

OUT=""; IPS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) [ $# -ge 2 ] || usage; OUT="$2"; shift ;;
    -*) usage ;;
    *)  IPS+=("$1") ;;
  esac
  shift
done
[ -n "$OUT" ] && [ "${#IPS[@]}" -gt 0 ] || usage

ensure_dirs "$OUT"

failed=()
for ip in "${IPS[@]}"; do
  log_step "$ip"
  # `|| rc=$?`: these scripts run with set -e, and a failing host must not end
  # the loop. grep exits 1 when a host has no crashes or hangs, which skips the
  # rsync exactly as the one-liner's && does.
  rc=0
  # A fresh staging directory per grab. It is filled with copies, so wiping it
  # loses nothing - and without the wipe every interrupted run leaves its files
  # for the next one to carry again: one host had 47k of them.
  # `cp -t` takes the files in batches; `cp {}` per file is 47k execs.
  # SC2029: $REMOTE_CAMPAIGN_DIR is meant to expand here, on the client - it is
  # this campaign's setting, not something the remote host defines.
  # shellcheck disable=SC2029
  ssh "root@$ip" "rm -rf /tmp/crashes && mkdir -p /tmp/crashes && find '$REMOTE_CAMPAIGN_DIR' -type f -name 'id*' | grep -P 'crashes' | xargs -r cp -t /tmp/crashes/ ; find '$REMOTE_CAMPAIGN_DIR' -type f -name 'id*' | grep -P 'hangs' | shuf | head -20 | xargs -r cp -t /tmp/crashes/" \
    && rsync -avz --progress -h --remove-source-files "root@$ip:/tmp/crashes/" "$OUT/" \
    || rc=$?
  if [ "$rc" -eq 0 ]; then
    log_ok "$ip: done"
  else
    log_err "$ip: failed (exit $rc)"
    failed+=("$ip")
  fi
done

log_ok "$(count_files "$OUT") files in $OUT"
[ "${#failed[@]}" -eq 0 ] || die "failed: ${failed[*]}"
