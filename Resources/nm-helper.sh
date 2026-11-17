#!/bin/sh
# NAS Mover helper: the fixed set of operations the runner performs on a NAS (busybox-compatible).
# Usage: nm-helper.sh VERB
#   Parameters arrive on stdin, one per line, followed by any payload (file lists, manifest text).
#   Nothing on stdin is ever executed: this replaces piping shell scripts to the other box.
#
# When NM_GUARD=1 (set by unas-gate.sh for the QNAP's key):
#   - every path must be inside a UniFi Drive share (/volume/<id>/.srv/.unifi-drive/<share>/.data)
#   - writes only inside shares listed in writable-shares (one share name per line, next to this script)
#   - recycling only into "_NAS Mover Recycle"; listed relative paths may not climb out with ".."

NM_HOME=${NM_HOME:-$(cd "$(dirname "$0")" && pwd)}
die() { echo "nm-helper: $*" >&2; exit 2; }
param() { IFS= read -r "$1" || die "missing parameter: $1"; }

SHARE_RE='^/volume/[0-9A-Za-z-]+/\.srv/\.unifi-drive/[^/]+/\.data(/.*)?$'

check() { # r|w path
	[ "$NM_GUARD" = 1 ] || return 0
	case "/$2/" in */../*|*/./*) die "refused: relative path component in $2" ;; esac
	real=$(realpath -m -- "$2" 2>/dev/null) || die "refused: can't resolve $2"
	printf '%s\n' "$2" | grep -Eq "$SHARE_RE" || die "refused: outside the UniFi Drive shares: $2"
	printf '%s\n' "$real" | grep -Eq "$SHARE_RE" || die "refused: resolves outside the UniFi Drive shares: $2"
	if [ "$1" = w ]; then
		s=$(printf '%s\n' "$real" | sed -E 's#^/volume/[^/]+/\.srv/\.unifi-drive/([^/]+)/.*#\1#')
		grep -qxF -- "$s" "$NM_HOME/writable-shares" 2>/dev/null || die "refused: share $s is not writable by NAS Mover"
	fi
}
check_bin() { # path must be inside a NAS Mover recycle folder
	[ "$NM_GUARD" = 1 ] || return 0
	case "$1" in *"/_NAS Mover Recycle/"?*) ;; *) die "refused: recycle destination must be inside _NAS Mover Recycle: $1" ;; esac
}
check_rel() { # relative paths read from stdin into file $1
	[ "$NM_GUARD" = 1 ] || return 0
	if grep -Eq '(^/)|(^|/)\.\.(/|$)' "$1"; then die "refused: a listed path is absolute or contains .."; fi
}
digits() { case "$1" in ''|*[!0-9]*) die "refused: not a number: $1" ;; esac; }

PRUNE_FIND='find . \( -name @Recycle -o -name "_NAS Mover Recycle" -o -name .@__thumb -o -name .@upload_cache -o -name .@__qini -o -name .trashcan -o -name .TemporaryItems -o -name .Trashes -o -name .Spotlight-V100 -o -name .fseventsd -o -name ascmhl -o -name .streams -o -name ".nasmover-staging-*" \) -prune -o -type f ! -name .DS_Store ! -name "._*" ! -name Thumbs.db -print'

case "$1" in

perms) # P O: hand root-written items under P to the UniFi Drive owner O
	param P; param O
	check w "$P"
	[ -z "$O" ] || printf '%s\n' "$O" | grep -Eq '^[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$' || die "refused: bad owner $O"
	[ -e "$P" ] || exit 0
	find "$P" -user root -type d -exec chmod 770 {} +
	find "$P" -user root -type f -exec chmod 660 {} +
	[ -n "$O" ] && find "$P" -user root -exec chown -h "$O" {} +
	;;

ls) # P
	param P
	check r "$P"
	cd "$P" && ls -A
	;;

mkdir) # P
	param P
	check w "$P"
	mkdir -p "$P"
	;;

hash) # R N MODE(FIND|LIST); LIST payload: relative paths
	param R; param N; param MODE
	digits "$N"
	check r "$R"
	L=/tmp/nasmover.$$.list
	trap 'rm -f "$L" "$L".c.*' EXIT
	if [ "$MODE" = LIST ]; then
		cat > "$L"
		check_rel "$L"
	fi
	cd "$R" || exit 1
	if [ "$MODE" != LIST ]; then
		eval "$PRUNE_FIND" | sed 's|^\./||' > "$L"
	fi
	echo "T $(wc -l < "$L" | tr -d ' ')"
	tr '\n' '\0' < "$L" | xargs -0 stat -c 'S %s %Y %n'
	awk -v n="$N" -v pre="$L.c." '{ f = pre "" (NR % n); print > f }' "$L"
	# Report each checksum as soon as it's done: GNU md5sum otherwise holds output in large buffers.
	# Each line must reach the shared output in one write, or the parallel workers' lines interleave
	# (mawk -W interactive writes unbuffered, piece by piece). GNU sed -u and busybox awk + fflush both write whole lines.
	SB=""
	command -v stdbuf >/dev/null 2>&1 && SB="stdbuf -oL"
	for c in "$L".c.*; do
		[ -f "$c" ] || continue
		if [ -n "$SB" ] && echo x | sed -u 's/^/H /' >/dev/null 2>&1; then
			tr '\n' '\0' < "$c" | xargs -0 $SB md5sum | sed -u 's/^/H /' &
		else
			tr '\n' '\0' < "$c" | xargs -0 md5sum | awk '{ print "H " $0; fflush() }' &
		fi
	done
	wait
	;;

history) # R: print every ASC MHL generation under R/ascmhl
	param R
	check r "$R"
	cd "$R/ascmhl" 2>/dev/null || exit 0
	ls | grep -E '^[0-9]+_.*\.mhl$' | sort | while IFS= read -r f; do echo "@@FILE $f"; cat "$f"; done
	;;

writemhl) # R NAME SEQ C4; payload: the manifest
	param R; param N; param S; param C
	check w "$R"
	case "$N" in */*|.*|'') die "refused: bad manifest name $N" ;; *.mhl) ;; *) die "refused: bad manifest name $N" ;; esac
	digits "$S"
	printf '%s\n' "$C" | grep -Eq '^c4[1-9A-HJ-NP-Za-km-z]+$' || die "refused: bad C4 id"
	mkdir -p "$R/ascmhl" && cd "$R/ascmhl" || exit 1
	cat > "$N" || exit 1
	entry="  <hashlist sequencenr=\"$S\">
    <path>$N</path>
    <c4>$C</c4>
  </hashlist>"
	if [ -f ascmhl_chain.xml ] && grep -q '</ascmhldirectory>' ascmhl_chain.xml; then
		grep -v '</ascmhldirectory>' ascmhl_chain.xml > ascmhl_chain.xml.tmp
	else
		printf '%s\n%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">' > ascmhl_chain.xml.tmp
	fi
	printf '%s\n%s\n' "$entry" '</ascmhldirectory>' >> ascmhl_chain.xml.tmp && mv ascmhl_chain.xml.tmp ascmhl_chain.xml
	;;

recycle) # MODE(CONTENTS|SELF|LIST) R D; LIST payload: relative paths
	param MODE; param R; param D
	check w "$R"; check w "$D"; check_bin "$D/"
	case "$MODE" in
	CONTENTS)
		cd "$R" || exit 1
		mkdir -p "$D" || exit 1
		fail=0
		for p in * .[!.]* ..?*; do
			[ -e "$p" ] || [ -L "$p" ] || continue
			# Leave the NAS's own system folders and the recycle folder itself.
			case "$p" in "_NAS Mover Recycle"|@*|.@*|.streams|.DS_Store|.trashcan|.TemporaryItems|.Trashes|.Spotlight-V100|.fseventsd) continue ;; esac
			mv "./$p" "$D/" || fail=1
		done
		exit $fail
		;;
	SELF)
		[ "$NM_GUARD" = 1 ] && case "$R" in */.data|*/.data/) die "refused: a share root can't move itself" ;; esac
		mkdir -p "$D" && mv "$R" "$D/"
		;;
	LIST)
		T=/tmp/nasmover.$$.rlist
		trap 'rm -f "$T"' EXIT
		cat > "$T"
		check_rel "$T"
		cd "$R" || exit 1
		while IFS= read -r p; do
			[ -e "$p" ] || [ -L "$p" ] || continue
			mkdir -p "$D/$(dirname "$p")" && mv "$p" "$D/$p"
		done < "$T"
		;;
	*) die "refused: bad recycle mode $MODE" ;;
	esac
	;;

beside) # STAGING DEST SUFFIX; payload: relative paths
	param S; param D; param X
	check w "$S"; check w "$D"
	[ "$NM_GUARD" = 1 ] && case "${S##*/}" in .nasmover-staging-?*) ;; *) die "refused: not a staging folder: $S" ;; esac
	case "$X" in */*) die "refused: bad suffix" ;; esac
	T=/tmp/nasmover.$$.blist
	trap 'rm -f "$T"' EXIT
	cat > "$T"
	check_rel "$T"
	fail=0
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		[ -f "$S/$p" ] || { echo "missing in staging: $p" >&2; fail=1; continue; }
		dir=$(dirname "$p"); base=$(basename "$p")
		case "$base" in ?*.*) stem=${base%.*}; ext=".${base##*.}" ;; *) stem=$base; ext="" ;; esac
		mkdir -p "$D/$dir" || { fail=1; continue; }
		t="$D/$dir/$stem$X$ext"; i=2
		while [ -e "$t" ]; do t="$D/$dir/$stem$X $i$ext"; i=$((i + 1)); done
		mv "$S/$p" "$t" || fail=1
	done < "$T"
	# Only remove the staging folder once nothing is left in it.
	[ -z "$(find "$S" -type f | head -1)" ] && rm -rf "$S"
	exit $fail
	;;

retirescan) # R: size, mtime and path of every file, to compare with what was checked
	param R
	check r "$R"
	cd "$R" || exit 1
	eval "$PRUNE_FIND" | sed 's|^\./||' | tr '\n' '\0' | xargs -0 -r stat -c '%s %Y %n'
	;;

*) die "unknown verb: $1" ;;
esac
