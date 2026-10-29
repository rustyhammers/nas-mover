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

TOOL_VERSION=1.1
J="$1"
cd "$J" || exit 1
. ./job.env

echo $$ > pid
RSH="ssh -o BatchMode=yes -o ServerAliveInterval=30 -c aes128-gcm@openssh.com"
# --whole-file: on a LAN, sending whole files beats rsync's delta algorithm.
# --progress: lets update_progress count bytes inside files that are still copying.
RS="rsync -rlt -s -W --progress --exclude-from=$EXCLUDES"
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
spec() { # host path -> rsync path
	if [ "$1" = "$RUNNER" ]; then printf '%s' "$2"; else printf '%s:%s' "$UNAS_SSH" "$2"; fi
}
on() { # host; runs the script on stdin there
	if [ "$1" = "$RUNNER" ]; then sh -s; else $RSH "$UNAS_SSH" sh -s; fi
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
	{
		printf 'P=%s\nO=%s\n' "$(q "$1")" "$(q "$UNAS_OWNER")"
		cat <<'EOS'
[ -e "$P" ] || exit 0
find "$P" -user root -type d -exec chmod 770 {} +
find "$P" -user root -type f -exec chmod 660 {} +
[ -n "$O" ] && find "$P" -user root -exec chown -h "$O" {} +
EOS
	} | on unas
}

bin_root() { # ".../_NAS Mover Recycle/<job>/..." -> ".../_NAS Mover Recycle", so folders mkdir created get fixed too
	printf '%s/_NAS Mover Recycle' "${1%%/_NAS Mover Recycle/*}"
}

load_copy() {
	eval "fh=\$COPY${1}_FROM_HOST fp=\$COPY${1}_FROM th=\$COPY${1}_TO_HOST tp=\$COPY${1}_TO list=\$COPY${1}_LIST bk=\$COPY${1}_BACKUP upd=\$COPY${1}_UPDATE"
	opts=""
	[ "$upd" = 1 ] && opts="-u"
	src=$(spec "$fh" "$fp/")
	dst=$(spec "$th" "$tp/")
}
rs() { # rsync with this step's options; backups go to the recycle bin
	if [ -n "$bk" ]; then $RS $opts -b "--backup-dir=$bk" "$@"; else $RS $opts "$@"; fi
}
make_chunks() { # n: split the work list into STREAMS chunk files
	if [ "$list" = ALL ]; then
		printf 'cd %s && ls -A\n' "$(q "$fp")" | on "$fh" > top.$1 || return 1
		L=top.$1
	else
		L=$list
	fi
	rm -f chunk.$1.*
	awk -v n="$STREAMS" -v pre="chunk.$1." '{ f = pre "" (NR % n); print > f }' "$L"
}

copy_op() {
	load_copy $1
	printf 'mkdir -p %s\n' "$(q "$tp")" | on "$th" || return 1
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
		printf 'R=%s\nN=%s\nL=/tmp/nasmover.$$.list\n' "$(q "$2")" "$STREAMS"
		if [ -n "$4" ]; then
			echo "cat > \"\$L\" <<'NASMOVER_EOF'"
			cat "$4"
			echo NASMOVER_EOF
		fi
		[ -n "$4" ] || echo 'FIND=1'
		cat <<'EOS'
cd "$R" || exit 1
if [ -n "$FIND" ]; then
	find . \( -name @Recycle -o -name "_NAS Mover Recycle" -o -name .@__thumb -o -name .@upload_cache -o -name .@__qini -o -name .trashcan \
		-o -name .TemporaryItems -o -name .Trashes -o -name .Spotlight-V100 -o -name .fseventsd -o -name ascmhl \) -prune \
		-o -type f ! -name .DS_Store ! -name '._*' ! -name Thumbs.db -print | sed 's|^\./||' > "$L"
fi
echo "T $(wc -l < "$L" | tr -d ' ')"
tr '\n' '\0' < "$L" | xargs -0 stat -c 'S %s %Y %n'
awk -v n="$N" -v pre="$L.c." '{ f = pre "" (NR % n); print > f }' "$L"
# Report each checksum as soon as it's done: GNU md5sum and mawk otherwise hold output in large buffers.
SB=""
command -v stdbuf >/dev/null 2>&1 && SB="stdbuf -oL"
AWKI="awk"
awk -W interactive 'BEGIN {}' </dev/null >/dev/null 2>&1 && AWKI="awk -W interactive"
for c in "$L".c.*; do
	[ -f "$c" ] || continue
	tr '\n' '\0' < "$c" | xargs -0 $SB md5sum | $AWKI '{ print "H " $0; fflush() }' &
done
wait
rm -f "$L" "$L".c.*
EOS
	} | on "$1" > hashraw.$3 2>> err.hash.$3
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
	{
		printf 'R=%s\n' "$(q "$2")"
		cat <<'EOS'
cd "$R/ascmhl" 2>/dev/null || exit 0
ls | grep -E '^[0-9]+_.*\.mhl$' | sort | while IFS= read -r f; do echo "@@FILE $f"; cat "$f"; done
EOS
	} | on "$1" > history.raw
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
		printf 'R=%s\nN=%s\nS=%s\nC=%s\n' "$(q "$2")" "$(q "$name")" "$NEXT_SEQ" "$c4"
		cat <<'EOS'
mkdir -p "$R/ascmhl" && cd "$R/ascmhl" || exit 1
cat > "$N" <<'NASMOVER_MHL_EOF'
EOS
		cat gen.mhl
		cat <<'EOS'
NASMOVER_MHL_EOF
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
EOS
	} | on "$1" || return 1
	[ "$1" = unas ] && fix_unas_perms "$2/ascmhl"
	echo "$name" >> manifests
	return 0
}

verify_op() { # n: MD5 both sides, compare; writes mismatch.n
	load_copy $1
	l=""
	[ "$list" = ALL ] || l="$list"
	hash_tree "$fh" "$fp" s$1 "$l" &
	a=$!
	hash_tree "$th" "$tp" d$1 "$l" &
	b=$!
	ok=0
	wait $a || { echo "could not hash every source file (see err.hash.s$1)" > mismatch.$1; ok=1; }
	wait $b || { echo "could not hash every destination file (see err.hash.d$1)" >> mismatch.$1; ok=1; }
	[ $ok = 0 ] || return 1
	compare_hashes s$1 d$1 "$upd" > mismatch.$1
	[ ! -s mismatch.$1 ]
}

recycle_op() {
	eval "h=\$RECYCLE${1}_HOST root=\$RECYCLE${1}_ROOT dest=\$RECYCLE${1}_DEST rlist=\$RECYCLE${1}_LIST"
	if [ "$rlist" = SELF ]; then
		{
			printf 'R=%s\nD=%s\n' "$(q "$root")" "$(q "$dest")"
			cat <<'EOS'
mkdir -p "$D" && mv "$R" "$D/"
EOS
		} | on "$h" || return 1
	else
		{
			printf 'R=%s\nD=%s\n' "$(q "$root")" "$(q "$dest")"
			cat <<'EOS'
cd "$R" || exit 1
while IFS= read -r p; do
	[ -e "$p" ] || [ -L "$p" ] || continue
	mkdir -p "$D/$(dirname "$p")" && mv "$p" "$D/$p"
done <<'NASMOVER_EOF'
EOS
			cat "$rlist"
			echo NASMOVER_EOF
		} | on "$h" || return 1
	fi
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
		if [ "$list" = ALL ]; then
			say "Writing ASC MHL manifest"
			write_mhl "$th" "$tp" d$n transfer original || warn=" (but the MHL manifest couldn't be written)"
		fi
		n=$((n + 1))
	done
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
