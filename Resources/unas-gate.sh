#!/bin/sh
# NAS Mover gate: the forced command for the QNAP's key on the UNAS.
# In root's authorized_keys:  from="<QNAP IP>",restrict,command="<home>/.nasmover/unas-gate.sh" ssh-ed25519 ...
#
# Allows only:
#   true                                 link check
#   sh .nasmover/nm-helper.sh <verb>     NAS Mover's fixed operations (paths checked by the helper)
#   rsync --server ...                   through rrsync: no deletes, paths inside the UniFi Drive shares,
#                                        and when receiving, only into shares listed in writable-shares
# Everything else is refused and logged to gate.log next to this script.

NM_HOME=$(cd "$(dirname "$0")" && pwd)
LOG=$NM_HOME/gate.log
C=$SSH_ORIGINAL_COMMAND

log() {
	printf '%s %s %s\n' "$(date '+%F %T')" "$1" "$(printf '%s' "$C" | tr '\n' ' ' | cut -c1-400)" >> "$LOG"
	# Keep the log small.
	[ "$(wc -l < "$LOG")" -gt 5000 ] && tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}
refuse() { log "REFUSED ($1)"; echo "NAS Mover gate refused this command: $1" >&2; exit 1; }

case "$C" in
	*"
"*) refuse "multi-line command" ;;
esac

case "$C" in
true)
	exit 0
	;;
"sh .nasmover/nm-helper.sh "*)
	verb=${C#"sh .nasmover/nm-helper.sh "}
	case "$verb" in
		perms|ls|mkdir|hash|history|writemhl|recycle|beside|retirescan) ;;
		*) refuse "unknown helper verb" ;;
	esac
	log "helper"
	NM_GUARD=1 NM_HOME=$NM_HOME exec sh "$NM_HOME/nm-helper.sh" "$verb"
	;;
"rsync --server "*)
	case " $C " in
		*" --sender "*) dir=read ;;
		*) dir=write ;;
	esac
	# Every share the command names must exist; when writing, each must be listed as writable.
	shares=$(printf '%s\n' "$C" | grep -o '/\.unifi-drive/[^/ ]*/' | sed 's#^/\.unifi-drive/##; s#/$##' | sort -u)
	[ -n "$shares" ] || refuse "rsync without a UniFi Drive share path"
	for s in $shares; do
		if [ "$dir" = write ] && ! grep -qxF -- "$s" "$NM_HOME/writable-shares" 2>/dev/null; then
			refuse "share $s is not writable by NAS Mover"
		fi
	done
	root=$(printf '%s\n' "$C" | grep -o '/volume/[0-9A-Za-z-]*/\.srv/\.unifi-drive/' | head -1)
	root=${root%/}
	[ -d "$root" ] || refuse "unknown volume"
	log "rsync-$dir"
	exec rrsync -absolute -no-del -no-lock "$root"
	;;
*)
	refuse "not a NAS Mover command"
	;;
esac
