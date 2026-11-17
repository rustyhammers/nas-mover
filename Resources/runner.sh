#!/bin/sh
# NAS Mover job runner. Runs on the NAS (busybox-compatible).
# Usage: runner.sh <job dir>
#
# job.env (written by the app) defines:
#   RUNNER         qnap|unas  - which box this script is running on
#   UNAS_SSH       ssh target for the UNAS when it is the remote side
#   UNAS_OWNER     owner:group for files written to the UNAS
#   STREAMS        parallel rsync / hashing streams
#   EXCLUDES       path to the rsync exclude file
#   VERIFY         1 = MD5-verify every copy step (and write an ASC MHL manifest for whole-folder copies)
#   COPYn_FROM_HOST COPYn_FROM COPYn_TO_HOST COPYn_TO
#   COPYn_LIST     ALL (whole folder) or a file of relative paths
#   COPYn_BACKUP   where overwritten files are kept (receiver side)
#   COPYn_UPDATE   1 = never overwrite a newer destination file
#   RECYCLEn_HOST RECYCLEn_ROOT RECYCLEn_DEST
#   RECYCLEn_LIST  SELF (move ROOT itself) or a file of relative paths
#   VF_PATH        Verify Folder job: folder on this box to check against its ASC MHL history
#   PURGE_LIST     Empty job: file of absolute paths to delete permanently (only inside _NAS Mover Recycle)
#   AUDIT_A_HOST AUDIT_A AUDIT_B_HOST AUDIT_B
#                  Checksum job: MD5 every file in both folders; the app compares hash.a and hash.b
#   BESIDE_HOST BESIDE_STAGING BESIDE_DEST BESIDE_SUFFIX BESIDE_LIST
#                  After verifying, move each listed file from STAGING to DEST as "name<SUFFIX>.ext", never overwriting
#   RETIRE_HOST RETIRE_ROOT RETIRE_EXPECT
#                  Before recycling, refuse unless ROOT still matches EXPECT (size TAB mtime TAB path) exactly
#   RECYCLEn_LIST  may also be CONTENTS: move everything inside ROOT (a share root can't move itself)
#   COPYn_FLAT     1 = Ingest: the listed card files all land directly in TO (no card folders), checked by file name
#   COPYn_CARD     Ingest: the card's display name, for the ledger
#   INGEST_LEDGER INGEST_SHOOT
#                  Ingest: after verifying, record every card file (size, date, name, MD5, where it went) in the ledger
#   CC_ROOT CC_LIST CC_SEARCH CC_SEARCH_NAME CC_CARD
#                  Card check job: is every listed card file in CC_SEARCH with the same MD5? (safe to format)

TOOL_VERSION=1.4
J="$1"
cd "$J" || exit 1
. ./job.env

echo $$ > pid
RSH="ssh -o BatchMode=yes -o ServerAliveInterval=30 -c aes128-gcm@openssh.com"
# --whole-file: on a LAN, sending whole files beats rsync's delta algorithm.
# --progress: lets update_progress count bytes inside files that are still copying.
# No -s: the UNAS side runs rsync through rrsync (unas-gate.sh), which must see the paths.
# Remote paths are backslash-escaped instead (esc), which works with or without the gate.
RS="rsync -rlt -W --progress --exclude-from=$EXCLUDES"
NMH="$(cd "$(dirname "$0")" && pwd)/nm-helper.sh"
TAB=$(printf '\t')

say() { echo "$*" > phase; echo "$(date '+%F %T') $*" >> events.log; }
finish() { # state result
	update_progress
	date +%s > finished
	echo "$2" > result
	echo "$1" > state
	say "$2"
	kill $PROG 2>/dev/null
	exit 0
}
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
esc() { # backslash-escape shell-special ASCII for a remote rsync path (bytes >= 0x80 pass through)
	printf '%s' "$1" | awk 'BEGIN { sp = " !\"#$&\047()*,;<=>?[\\]^`{|}~" } {
		out = ""; n = length($0)
		for (i = 1; i <= n; i++) { c = substr($0, i, 1); if (index(sp, c)) out = out "\\" c; else out = out c }
		printf "%s%s", (NR > 1 ? "\n" : ""), out }'
}
spec() { # host path -> rsync path
	if [ "$1" = "$RUNNER" ]; then printf '%s' "$2"; else printf '%s:%s' "$UNAS_SSH" "$(esc "$2")"; fi
}
nm() { # host verb: runs a fixed nm-helper.sh operation there; parameters and payload on stdin
	if [ "$1" = "$RUNNER" ]; then sh "$NMH" "$2"; else $RSH "$UNAS_SSH" "sh .nasmover/nm-helper.sh $2"; fi
}
# progress = "<files done> <bytes done>", including the part of each worker's current file already sent.
# Each worker log interleaves our --out-format lines (flags|size|path) with rsync's \r-separated --progress lines.
update_progress() {
	[ -n "$PURGE_LIST" ] && return   # purge() writes its own progress
	for f in log.*; do
		[ -f "$f" ] || continue
		tr '\r' '\n' < "$f" | awk -F'|' '
			NF >= 3 && $1 ~ /^[<>]f/ { if (pend) { done += cur; n++ } cur = $2; pend = 1; part = 0; next }
			/^ *[0-9]+ +[0-9]+%/ {
				split($0, a, " "); part = a[1]
				if ($0 ~ / 100%/ || $0 ~ /xfer#/) { if (pend) { done += cur; n++ } pend = 0 }
			}
			END { if (pend) done += part; printf "%d %.0f\n", n, done }'
	done | awk '{ n += $1; b += $2 } END { printf "%d %.0f\n", n, b }' > progress.tmp && mv progress.tmp progress
	cat hashraw.* 2>/dev/null | awk '$1 == "H" { h++ } $1 == "T" { t += $2 } END { printf "%d %d\n", h, t }' > hprogress.tmp && mv hprogress.tmp hprogress
	# hbytes = "host:hashed:total" per NAS, by data rather than file count (one big file can take minutes).
	for r in hashraw.*; do
		[ -f "$r" ] || continue
		tag=${r#hashraw.}
		awk -v host="$(cat hhost.$tag 2>/dev/null)" '
			$1 == "S" { p = $0; sub(/^S [0-9]+ [0-9]+ /, "", p); sz[p] = $2; all += $2; next }
			$1 == "H" { l = substr($0, 3); if (substr(l, 1, 1) == "\\") l = substr(l, 2); hb += sz[substr(l, 35)] }
			END { printf "%s %.0f %.0f\n", host, hb, all }' "$r"
	done | awk '{ h[$1] += $2; t[$1] += $3 } END { for (k in h) printf "%s:%.0f:%.0f\n", k, h[k], t[k] }' | tr '\n' ',' > hbytes.tmp && mv hbytes.tmp hbytes
}
progress_loop() { while :; do update_progress; sleep 2; done; }

fix_unas_perms() { # path on the UNAS: hand root-written items to the UniFi Drive owner
	printf '%s\n%s\n' "$1" "$UNAS_OWNER" | nm unas perms
}

bin_root() { # ".../_NAS Mover Recycle/<job>/..." -> ".../_NAS Mover Recycle", so folders mkdir created get fixed too
	printf '%s/_NAS Mover Recycle' "${1%%/_NAS Mover Recycle/*}"
}

load_copy() {
	ci=$1
	eval "fh=\$COPY${1}_FROM_HOST fp=\$COPY${1}_FROM th=\$COPY${1}_TO_HOST tp=\$COPY${1}_TO list=\$COPY${1}_LIST bk=\$COPY${1}_BACKUP upd=\$COPY${1}_UPDATE flat=\$COPY${1}_FLAT"
	opts=""
	[ "$upd" = 1 ] && opts="-u"
	[ "$flat" = 1 ] && opts="$opts --no-relative"
	src=$(spec "$fh" "$fp/")
	dst=$(spec "$th" "$tp/")
}
rs() { # rsync with this step's options; backups go to the recycle bin
	if [ -z "$bk" ]; then $RS $opts "$@"
	elif [ "$th" != "$RUNNER" ]; then $RS $opts -b "--backup-dir=$(esc "$bk")" "$@"
	elif [ "$fh" = "$RUNNER" ]; then $RS $opts -b "--backup-dir=$bk" "$@"
	else
		# Pulling from the UNAS: rsync 3.0.7 also sends --backup-dir to the remote sender, unquoted,
		# so give it a link without spaces (the job folder) that points at the real backup folder.
		mkdir -p "$bk" && ln -sfn "$bk" "$(pwd)/backup.$ci" || return 1
		$RS $opts -b "--backup-dir=$(pwd)/backup.$ci" "$@"
	fi
}
make_chunks() { # n: split the work list into STREAMS chunk files
	if [ "$list" = ALL ]; then
		printf '%s\n' "$fp" | nm "$fh" ls > top.$1 || return 1
		L=top.$1
	else
		L=$list
	fi
	rm -f chunk.$1.*
	awk -v n="$STREAMS" -v pre="chunk.$1." '{ f = pre "" (NR % n); print > f }' "$L"
}

copy_op() {
	load_copy $1
	printf '%s\n' "$tp" | nm "$th" mkdir || return 1
	make_chunks $1 || return 1
	pids=""
	i=0
	for c in chunk.$1.*; do
		[ -f "$c" ] || continue
		rs "--files-from=$c" --out-format='%i|%l|%n' -e "$RSH" "$src" "$dst" >> log.$1.$i 2>> err.$1.$i &
		pids="$pids $!"
		i=$((i + 1))
	done
	rc=0
	for p in $pids; do
		wait $p
		r=$?
		[ $r -eq 0 ] || [ $r -eq 24 ] || rc=$r
	done
	if [ "$list" = ALL ]; then
		# Catch-up pass: picks up anything added since the work list was made.
		rs --out-format='%i|%l|%n' -e "$RSH" "$src" "$dst" >> log.$1.final 2>> err.$1.final
		r=$?
		[ $r -eq 0 ] || [ $r -eq 24 ] || rc=$r
	fi
	if [ "$th" = unas ]; then
		say "Setting UNAS file permissions"
		fix_unas_perms "$tp"
		[ -n "$bk" ] && fix_unas_perms "$(bin_root "$bk")"
	fi
	return $rc
}

# --- Checksums -------------------------------------------------------------

# hash_tree host root tag [listfile]
# MD5s every file under root (or just the listed ones) on that host, STREAMS at a time.
# Writes hash.<tag> (md5 TAB path) and stat.<tag> (size TAB mtime TAB path).
# Returns 1 if any file couldn't be hashed.
hash_tree() {
	echo "$1" > hhost.$3
	{
		printf '%s\n%s\n' "$2" "$STREAMS"
		if [ -n "$4" ]; then echo LIST; cat "$4"; else echo FIND; fi
	} | nm "$1" hash > hashraw.$3 2>> err.hash.$3
	awk -v H="hash.$3" -v S="stat.$3" '
		$1 == "T" { total = $2; next }
		$1 == "H" {
			line = substr($0, 3)
			if (substr(line, 1, 1) == "\\") line = substr(line, 2)   # GNU md5sum escapes odd names; they will fail safe
			print substr(line, 1, 32) "\t" substr(line, 35) > H; h++; next
		}
		$1 == "S" { p = $0; sub(/^S [0-9]+ [0-9]+ /, "", p); print $2 "\t" $3 "\t" p > S; next }
		END { printf "" > H; printf "" > S; if (total == "" || h + 0 != total + 0) exit 1; exit 0 }' hashraw.$3
}

# compare src_tag dst_tag update -> prints problems; for -u copies a newer destination file is not a problem
compare_hashes() {
	awk -F'\t' -v upd="$3" '
		FILENAME == ARGV[1] { sh[$2] = $1; next }
		FILENAME == ARGV[2] { dh[$2] = $1; next }
		FILENAME == ARGV[3] { sm[$3] = $2; next }
		FILENAME == ARGV[4] { dm[$3] = $2; next }
		END {
			for (p in sh) {
				if (!(p in dh)) print "missing at destination: " p
				else if (sh[p] != dh[p] && !(upd == 1 && dm[p] > sm[p])) print "checksum mismatch: " p
			}
		}' hash.$1 hash.$2 stat.$1 stat.$2
}

sha512_hex() { # file
	if command -v sha512sum >/dev/null 2>&1; then sha512sum "$1" | cut -d' ' -f1; else openssl dgst -sha512 -r "$1" | cut -d' ' -f1; fi
}

c4_id() { # file -> C4 ID (base58 SHA-512, as used by the ASC MHL chain)
	sha512_hex "$1" | awk '{
		a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
		n = length($1)
		for (i = 1; i <= n; i++) d[i] = index("0123456789abcdef", substr($1, i, 1)) - 1
		out = ""
		while (1) {
			zero = 1; rem = 0
			for (i = 1; i <= n; i++) { cur = rem * 16 + d[i]; d[i] = int(cur / 58); rem = cur % 58; if (d[i]) zero = 0 }
			out = substr(a, rem + 1, 1) out
			if (zero) break
		}
		while (length(out) < 88) out = "1" out
		print "c4" out
	}'
}

# Pulls the existing ASC MHL history for root: prev.tsv (md5 TAB path TAB lastmodificationdate), latest wins.
# Also sets NEXT_SEQ.
load_history() { # host root
	printf '%s\n' "$2" | nm "$1" history > history.raw
	NEXT_SEQ=$(awk '/^@@FILE / { s = $2; sub(/_.*/, "", s); s = s + 0; if (s > m) m = s } END { print m + 1 }' history.raw)
	# Only <hash> entries describe files; skip directory and root hashes.
	awk '
		function unesc(s) { gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&quot;/, "\"", s); gsub(/&apos;/, "\047", s); gsub(/&amp;/, "\\&", s); return s }
		/<hash>/ { inhash = 1; p = ""; dt = "" }
		/<\/hash>/ { inhash = 0 }
		!inhash { next }
		/<path[ >]/ {
			p = $0; sub(/.*<path[^>]*>/, "", p); sub(/<\/path>.*/, "", p); p = unesc(p)
			dt = ""
			if (match($0, /lastmodificationdate="[^"]*"/)) dt = substr($0, RSTART + 22, RLENGTH - 23)
		}
		/<md5[ >]/ { h = $0; sub(/.*<md5[^>]*>/, "", h); sub(/<\/md5>.*/, "", h); print h "\t" p "\t" dt }
	' history.raw > prev.tsv
}

# write_mhl host root tag process failaction
# Writes the next ASC MHL generation for root (from hash.<tag>/stat.<tag>) plus the chain file.
write_mhl() {
	load_history "$1" "$2"
	now=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
	stamp=$(date -u +%Y-%m-%d_%H%M%SZ)
	folder=$(basename "$2")
	name=$(printf '%04d_%s_%s.mhl' "$NEXT_SEQ" "$folder" "$stamp")
	sort -t "$TAB" -k2 hash.$3 > hash.$3.sorted
	awk -F'\t' -v now="$now" -v host="$(hostname)" -v proc="$4" -v fail="$5" -v ver="$TOOL_VERSION" '
		function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s); return s }
		function iso(t,   d, s, z, era, doe, yoe, y, doy, mp, dd, m) {
			d = int(t / 86400); s = t - d * 86400
			z = d + 719468; era = int((z >= 0 ? z : z - 146096) / 146097); doe = z - era * 146097
			yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
			y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100)); mp = int((5 * doy + 2) / 153)
			dd = doy - int((153 * mp + 2) / 5) + 1; m = mp + (mp < 10 ? 3 : -9); if (m <= 2) y++
			return sprintf("%04d-%02d-%02dT%02d:%02d:%02d+00:00", y, m, dd, int(s / 3600), int((s % 3600) / 60), s % 60)
		}
		BEGIN {
			print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
			print "<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">"
			print "  <creatorinfo>"
			print "    <creationdate>" now "</creationdate>"
			print "    <hostname>" esc(host) "</hostname>"
			print "    <tool version=\"" ver "\">NAS Mover</tool>"
			print "  </creatorinfo>"
			print "  <processinfo>"
			print "    <process>" proc "</process>"
			print "    <ignore>"
			n = split(".DS_Store ascmhl ascmhl/ ._* Thumbs.db @Recycle .@__thumb .trashcan .TemporaryItems .Trashes .Spotlight-V100 .fseventsd", ig, " ")
			for (i = 1; i <= n; i++) print "      <pattern>" esc(ig[i]) "</pattern>"
			print "      <pattern>_NAS Mover Recycle</pattern>"
			print "    </ignore>"
			print "  </processinfo>"
			print "  <hashes>"
		}
		FILENAME == ARGV[1] { prev[$2] = $1; next }
		FILENAME == ARGV[2] { sz[$3] = $1; mt[$3] = $2; next }
		{
			p = $2; h = $1
			a = (p in prev) ? (prev[p] == h ? "verified" : fail) : "original"
			print "    <hash>"
			print "      <path size=\"" sz[p] "\" lastmodificationdate=\"" iso(mt[p]) "\">" esc(p) "</path>"
			print "      <md5 action=\"" a "\" hashdate=\"" now "\">" h "</md5>"
			print "    </hash>"
		}
		END { print "  </hashes>"; print "</hashlist>" }
	' prev.tsv stat.$3 hash.$3.sorted > gen.mhl
	c4=$(c4_id gen.mhl)
	{
		printf '%s\n%s\n%s\n%s\n' "$2" "$name" "$NEXT_SEQ" "$c4"
		cat gen.mhl
	} | nm "$1" writemhl || return 1
	[ "$1" = unas ] && fix_unas_perms "$2/ascmhl"
	echo "$name" >> manifests
	return 0
}

verify_op() { # n: MD5 both sides, compare; writes mismatch.n
	load_copy $1
	l=""
	[ "$list" = ALL ] || l="$list"
	dl="$l"
	if [ "$flat" = 1 ]; then
		sed 's|.*/||' "$list" > flat.$1
		dl=flat.$1
	fi
	hash_tree "$fh" "$fp" s$1 "$l" &
	a=$!
	hash_tree "$th" "$tp" d$1 "$dl" &
	b=$!
	ok=0
	wait $a || { echo "could not hash every source file (see err.hash.s$1)" > mismatch.$1; ok=1; }
	wait $b || { echo "could not hash every destination file (see err.hash.d$1)" >> mismatch.$1; ok=1; }
	[ $ok = 0 ] || return 1
	if [ "$flat" = 1 ]; then
		# The card's folders were dropped on the way, so compare by file name.
		awk -F'\t' -v OFS='\t' '{ n = $2; sub(/.*\//, "", n); print $1, n }' hash.s$1 > hash.f$1
		awk -F'\t' -v OFS='\t' '{ n = $3; sub(/.*\//, "", n); print $1, $2, n }' stat.s$1 > stat.f$1
		compare_hashes f$1 d$1 "$upd" > mismatch.$1
	else
		compare_hashes s$1 d$1 "$upd" > mismatch.$1
	fi
	[ ! -s mismatch.$1 ]
}

recycle_op() {
	eval "h=\$RECYCLE${1}_HOST root=\$RECYCLE${1}_ROOT dest=\$RECYCLE${1}_DEST rlist=\$RECYCLE${1}_LIST"
	case "$rlist" in
		CONTENTS|SELF) printf '%s\n%s\n%s\n' "$rlist" "$root" "$dest" | nm "$h" recycle || return 1 ;;
		*) { printf 'LIST\n%s\n%s\n' "$root" "$dest"; cat "$rlist"; } | nm "$h" recycle || return 1 ;;
	esac
	[ "$h" = unas ] && fix_unas_perms "$(bin_root "$dest")"
	return 0
}

# --- Verify Folder job ------------------------------------------------------

verify_folder() {
	say "Hashing every file (MD5)"
	hash_tree "$RUNNER" "$VF_PATH" vf || finish failed "Couldn't read every file in the folder (see log)"
	load_history "$RUNNER" "$VF_PATH"
	had=$([ -s prev.tsv ] && echo 1 || echo 0)
	awk -F'\t' '
		function iso(t,   d, s, z, era, doe, yoe, y, doy, mp, dd, m) {
			d = int(t / 86400); s = t - d * 86400
			z = d + 719468; era = int((z >= 0 ? z : z - 146096) / 146097); doe = z - era * 146097
			yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
			y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100)); mp = int((5 * doy + 2) / 153)
			dd = doy - int((153 * mp + 2) / 5) + 1; m = mp + (mp < 10 ? 3 : -9); if (m <= 2) y++
			return sprintf("%04d-%02d-%02dT%02d:%02d:%02d+00:00", y, m, dd, int(s / 3600), int((s % 3600) / 60), s % 60)
		}
		FILENAME == ARGV[1] { ph[$2] = $1; pd[$2] = $3; next }
		FILENAME == ARGV[2] { mt[$3] = $2; next }
		{
			seen[$2] = 1
			if (!($2 in ph)) { nw++; print "new (not in manifest): " $2 > "vf.new"; next }
			if (ph[$2] == $1) { ok++; next }
			if (pd[$2] != "" && pd[$2] == iso(mt[$2])) { bad++; print "CORRUPT? same date, different contents: " $2 > "vf.problems" }
			else { mod++; print "modified since last manifest: " $2 > "vf.modified" }
		}
		END {
			for (p in ph) if (!(p in seen)) { miss++; print "MISSING: " p > "vf.problems" }
			printf "%d %d %d %d %d\n", ok, nw, mod, bad, miss > "vf.counts"
		}' prev.tsv stat.vf hash.vf
	set -- $(cat vf.counts)
	ok=$1 nw=$2 mod=$3 bad=$4 miss=$5
	say "Writing ASC MHL manifest"
	write_mhl "$RUNNER" "$VF_PATH" vf in-place failed || finish failed "Hashed OK, but couldn't write the manifest"
	[ "$RUNNER" = unas ] && fix_unas_perms "$VF_PATH/ascmhl"
	if [ "$had" = 0 ]; then
		finish done "Created first checksum manifest: $(wc -l < hash.vf | tr -d ' ') files"
	elif [ $((bad + miss)) -gt 0 ]; then
		finish failed "Problems: $bad possibly corrupt, $miss missing ($ok verified, $mod modified, $nw new)"
	else
		finish done "$ok files verified ($mod modified, $nw new since last manifest)"
	fi
}

# --- Ingest ----------------------------------------------------------------------

# Records each verified card file: size, date, name, MD5, where it went, shoot, card, day.
ledger_add() { # n
	load_copy $1
	[ "$flat" = 1 ] || return 0
	mkdir -p "$(dirname "$INGEST_LEDGER")"
	eval "card=\$COPY${1}_CARD"
	awk -F'\t' -v OFS='\t' -v dest="$tp" -v shoot="$INGEST_SHOOT" -v card="$card" -v when="$(date +%F)" '
		FILENAME == ARGV[1] { h[$2] = $1; next }
		($3 in h) { n = $3; sub(/.*\//, "", n); print $1, $2, n, h[$3], dest "/" n, shoot, card, when }' hash.s$1 stat.s$1 >> "$INGEST_LEDGER"
}

# Safe to format? Every listed card file must have a copy in CC_SEARCH with the same name and MD5.
card_check() {
	say "Hashing the card (MD5)"
	hash_tree "$RUNNER" "$CC_ROOT" cc "$CC_LIST" || finish failed "Couldn't read every file on the card (see log). NOT safe to format."
	say "Looking for copies in $CC_SEARCH_NAME"
	(
		cd "$CC_SEARCH" || exit 1
		find . \( -name @Recycle -o -name "_NAS Mover Recycle" -o -name .streams -o -name ascmhl -o -name .@__thumb -o -name '.nasmover-staging-*' \) -prune \
			-o -type f -print | sed 's|^\./||' | tr '\n' '\0' | xargs -0 -r stat -c '%s %n'
	) > cc.all 2>> err.cc
	# Candidates: same name and size as a card file.
	awk -F'\t' 'FILENAME == ARGV[1] { n = $3; sub(/.*\//, "", n); want[n "/" $1] = 1; next }
		{ size = $0; sub(/ .*/, "", size); p = $0; sub(/^[0-9]+ /, "", p); n = p; sub(/.*\//, "", n); if ((n "/" size) in want) print p }' stat.cc cc.all > cc.cand
	: > hash.cand
	: > stat.cand
	if [ -s cc.cand ]; then
		say "Hashing the matching files in $CC_SEARCH_NAME"
		hash_tree "$RUNNER" "$CC_SEARCH" cand cc.cand
	fi
	mkdir -p "$(dirname "$INGEST_LEDGER")"
	awk -F'\t' -v OFS='\t' -v root="$CC_SEARCH" -v card="$CC_CARD" -v when="$(date +%F)" -v led="$INGEST_LEDGER" '
		FILENAME == ARGV[1] { n = $2; sub(/.*\//, "", n); have[n "/" $1] = $2; next }
		FILENAME == ARGV[2] { sz[$3] = $1; mt[$3] = $2; next }
		{
			n = $2; sub(/.*\//, "", n)
			if ((n "/" $1) in have) {
				ok++
				p = have[n "/" $1]; shoot = p; sub(/\/[^\/]*$/, "", shoot)
				print sz[$2], mt[$2], n, $1, root "/" p, root "/" shoot, card, when >> led
			} else { miss++; print $2 > "cc.missing" }
		}
		END { printf "%d %d\n", ok, miss > "cc.counts" }' hash.cand stat.cc hash.cc
	set -- $(cat cc.counts)
	total=$(($1 + $2))
	if [ "$2" -gt 0 ]; then
		finish failed "NOT safe to format: $2 of $total files have no matching copy in $CC_SEARCH_NAME (list in log)"
	fi
	finish done "Safe to format: all $total files have a verified copy in $CC_SEARCH_NAME"
}

# --- Checksum two folders (Unify / Retire) -----------------------------------

audit() {
	say "Hashing both sides (MD5, reading every file)"
	hash_tree "$AUDIT_A_HOST" "$AUDIT_A" a &
	a=$!
	hash_tree "$AUDIT_B_HOST" "$AUDIT_B" b &
	b=$!
	ok=0
	wait $a || ok=1
	wait $b || ok=1
	na=$(wc -l < hash.a | tr -d ' ')
	nb=$(wc -l < hash.b | tr -d ' ')
	[ $ok = 0 ] || finish failed "Checksummed $na and $nb files, but some couldn't be read or changed while reading (see log)"
	finish done "Checksummed $na and $nb files"
}

# --- Retire helpers -------------------------------------------------------------

# Moves verified files out of the staging folder to sit beside the live ones as "name<suffix>.ext".
beside_op() {
	{
		printf '%s\n%s\n%s\n' "$BESIDE_STAGING" "$BESIDE_DEST" "$BESIDE_SUFFIX"
		cat "$BESIDE_LIST"
	} | nm "$BESIDE_HOST" beside 2>> err.beside || return 1
	[ "$BESIDE_HOST" = unas ] && fix_unas_perms "$BESIDE_DEST"
	return 0
}

# Refuses to retire if anything in the stale folder changed since it was checked.
retire_check() {
	printf '%s\n' "$RETIRE_ROOT" | nm "$RETIRE_HOST" retirescan > retire.now 2>> err.retire || return 1
	awk -F'\t' '
		FILENAME == ARGV[1] { want[$3] = $1 " " $2; next }
		{
			p = $0; sub(/^[0-9]+ [0-9]+ /, "", p)
			split($0, f, " ")
			if (!(p in want)) { print "new since the check: " p; continue }
			if (want[p] != f[1] " " f[2]) print "changed since the check: " p
			seen[p] = 1
		}
		END { for (p in want) if (!(p in seen)) print "gone since the check: " p }' "$RETIRE_EXPECT" retire.now > retire.problems
	[ ! -s retire.problems ]
}

# --- Empty job ----------------------------------------------------------------

purge() {
	total=$(grep -c . "$PURGE_LIST")
	i=0
	done_n=0
	skipped=0
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		i=$((i + 1))
		# Hard limit: only ever delete things inside a NAS Mover recycle folder.
		case "$p" in
			*"/_NAS Mover Recycle/"?*) ;;
			*) echo "refused (not in _NAS Mover Recycle): $p" >> err.purge; skipped=$((skipped + 1)); continue ;;
		esac
		case "$p" in *"/../"*|*"/.."|*"/./"*) echo "refused (relative path): $p" >> err.purge; skipped=$((skipped + 1)); continue ;; esac
		say "Permanently deleting $i of $total"
		rm -rf "$p" && done_n=$((done_n + 1))
		echo "$done_n 0" > progress
	done < "$PURGE_LIST"
	if [ $skipped -gt 0 ]; then
		finish failed "Deleted $done_n item(s); refused $skipped outside _NAS Mover Recycle"
	fi
	finish done "Permanently deleted $done_n item(s)"
}

# --- Main --------------------------------------------------------------------

on_cancel() {
	trap '' TERM INT
	kill -TERM 0 2>/dev/null   # rsync workers, hashing and the progress loop (this shell ignores it)
	sleep 1
	say "Cancelling: tidying up permissions"
	n=1
	while eval "[ -n \"\$COPY${n}_FROM\" ]"; do
		load_copy $n
		[ "$th" = unas ] && fix_unas_perms "$tp"
		n=$((n + 1))
	done
	update_progress
	date +%s > finished
	echo "Cancelled. Files copied so far were kept; running it again picks up where it stopped." > result
	echo cancelled > state
	exit 1
}
trap on_cancel TERM INT
echo running > state
date +%s > started
progress_loop &
PROG=$!

[ -n "$VF_PATH" ] && verify_folder
[ -n "$PURGE_LIST" ] && { kill $PROG 2>/dev/null; purge; }
[ -n "$AUDIT_A" ] && audit
[ -n "$CC_ROOT" ] && card_check
# Ingested files follow the share's default (rw for everyone), like files saved over SMB.
[ -n "$INGEST_LEDGER" ] && umask 000

n=1
while eval "[ -n \"\$COPY${n}_FROM\" ]"; do
	say "Copying"
	copy_op $n || finish failed "Copy failed (rsync error, see log)"
	n=$((n + 1))
done

warn=""
if [ "$VERIFY" = 1 ]; then
	n=1
	bad=0
	while eval "[ -n \"\$COPY${n}_FROM\" ]"; do
		say "Verifying with MD5 checksums (reading every file on both sides)"
		verify_op $n || bad=1
		n=$((n + 1))
	done
	if [ $bad = 1 ]; then
		cnt=$(cat mismatch.* | wc -l | tr -d ' ')
		finish failed "Verification failed: $cnt problem(s). Nothing was recycled."
	fi
	n=1
	while eval "[ -n \"\$COPY${n}_FROM\" ]"; do
		load_copy $n
		if [ "$list" = ALL ] || [ "$flat" = 1 ]; then
			say "Writing ASC MHL manifest"
			write_mhl "$th" "$tp" d$n transfer original || warn=" (but the MHL manifest couldn't be written)"
		fi
		n=$((n + 1))
	done
fi

if [ -n "$INGEST_LEDGER" ]; then
	n=1
	while eval "[ -n \"\$COPY${n}_FROM\" ]"; do
		ledger_add $n
		n=$((n + 1))
	done
fi

if [ -n "$BESIDE_LIST" ]; then
	say "Placing differing files beside the live ones"
	beside_op || finish failed "Copied and verified, but couldn't place every file beside the live ones (see log). Nothing was retired."
fi

if [ -n "$RETIRE_ROOT" ]; then
	say "Checking the stale copy hasn't changed"
	if ! retire_check; then
		cnt=$(wc -l < retire.problems | tr -d ' ')
		finish failed "Everything was copied and verified, but the stale copy changed since it was checked ($cnt file(s), see log). It was NOT retired; run Retire again."
	fi
fi

n=1
while eval "[ -n \"\$RECYCLE${n}_HOST\" ]"; do
	say "Moving originals to _NAS Mover Recycle"
	recycle_op $n || finish failed "Recycle step failed"
	n=$((n + 1))
done

if [ "$VERIFY" = 1 ]; then
	finish done "Done and verified$warn"
else
	finish done "Done (not verified)"
fi
