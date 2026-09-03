#!/bin/bash
# =====================================================================
#  storage-backup-en.sh   (runs on the storage server; deployed as
#                          data_backup_simple_code10.sh)
#     Moves run folders out of /data/RAW onto external disks, deleting
#     the source only after the copy has been verified.
#
#  * Just run it. No options needed.   ./data_backup_simple_code10.sh
#
#  Two things this does that code8 did not
#    1) It uses several disks in turn.  /backup_hdd -> /backup_hdd_2
#       When one fills up it carries straight on to the next.
#       * If the next disk is not mounted, or has no room, it says so
#         and stops rather than leaving data behind quietly.
#    2) It reports by mail: one when a disk fills and it moves on, one
#       when the session ends, one when it stops on an error. The body
#       carries the disk's device, UUID, model and serial.
#
#       * This server has no route to the internet (10.0.0.0/24 only,
#         and no DNS), so it cannot send mail itself. It drops a file
#         into /data/MAILQ instead. The DAQ PC has that same directory
#         mounted as /scratch, and a cron job there picks it up and
#         sends it via scripts/mailq-send.sh -> tools/notify/send_mail.py.
#         If /scratch is briefly absent the queue simply waits.
#
#  What one pass over one disk does
#    1) Works out what will fit and shows it before moving anything
#         - runs and subrun ranges, file counts, size, estimated time
#    2) Moves it, filling the disk completely
#         - a folder that does not fit is sliced to what does fit
#         - a run larger than the whole disk (there is a 6.7 TB one) is
#           spread over several disks, and a manifest records which
#           piece went where
#    3) Compares file count and bytes, and deletes from the source only
#       what passed
#
#  How it decides what to do after a pass
#    Nothing left to move (source empty, or all that remains is in use)
#          -> success. The next disk is not touched at all
#    Work remains  +  this disk is genuinely full
#          -> move on to the next disk
#    Work remains  +  this disk is not full  (--split never, big run)
#          -> a different disk would not help. Say why and stop, rather
#             than burning through disks
#
#  Guards against colliding with other work (unchanged from code8)
#    - Cannot run twice at once (flock + a process check that also
#      catches an older version someone started by hand)
#    - Leaves alone any run whose files changed in the last 30 minutes
#    - Leaves alone any run with a leftover .rsync-partial
#    - Skips runs listed in backup_log/backup_skip.txt
#    - Re-checks each file's size just before deleting it, and keeps
#      anything that changed while the transfer was running
#
#  Exit codes
#    0  normal (nothing more to move)
#    1  error (next disk missing or full, repeated transfer failures,
#       bad configuration)
#    3  all disks used and work remains -> swap a disk and run again
#
#  Options you will rarely need
#     --dry-run        show the plan and stop. Moves and deletes nothing
#     --disks a,b      disks to use, in order (default
#                      /backup_hdd,/backup_hdd_2)
#     --no-mail        do not queue any mail
#     --no-bwlimit     no speed limit (default 50M)
#     --margin 10      safety margin in GB (default 2)
#     --split auto     when you would rather a run not be spread over
#                      several disks. Only slices runs bigger than the
#                      whole disk (at the cost of leaving space unused)
# =====================================================================
# =====================================================================

# --- Configuration ----------------------------------------------------
SOURCE_PARENT="${BACKUP_SOURCE:-/data/RAW}"          # source tree to back up
#  * Disks to use, in order. Comma separated. --disks does the same.
MOUNTS_RAW="${BACKUP_MOUNTS:-/backup_hdd,/backup_hdd_2}"
DEST_SUBDIR="${BACKUP_DEST_SUBDIR:-RENE_data_backup}"
LOG_FILE="${BACKUP_LOG:-/home/frontend/sykim/backup_log/backup_log.txt}"
SIZE_CACHE="${BACKUP_SIZE_CACHE:-/home/frontend/sykim/backup_log/folder_size.cache}"

#  Safety margin -- room kept so the filesystem is never filled to the last
#  byte. rsync only needs space for the one file in flight (the largest DAQ
#  file is about 80 MB), so 2 GB is 25x what is needed. 10 GB would throw away
#  8 GB on every disk. To be more conservative:  --margin 10  (in GB)
SAFETY_MARGIN="${BACKUP_SAFETY_MARGIN_KB:-$((2 * 1024 * 1024))}"   # 2 GB [KB]
#  Below this much free space there is nothing useful left to place, so the disk
#  counts as full. DAQ files are 9-80 MB, so 100 MB packs it to the last file.
MIN_USEFUL="${BACKUP_MIN_USEFUL_KB:-$((100 * 1024))}"              # 100 MB [KB]
BWLIMIT="${BACKUP_BWLIMIT-50M}"       # empty = unlimited. --no-bwlimit clears it too
MAX_CONSEC_FAIL=3                     # this many failures in a row: suspect the disk and stop
#  What to do with a folder that does not fit
#    always: slice anything that does not fit the space left  * default.
#    auto  : only slice folders larger than the whole disk.
#    never : never slice (skip only)
SPLIT_MODE="${BACKUP_SPLIT_MODE:-always}"
PARTS_INDEX="${BACKUP_PARTS_INDEX:-/home/frontend/sykim/backup_log/parts_index.txt}"
LOCK="${BACKUP_LOCK:-/home/frontend/sykim/backup_log/.backup.lock}"
#  * Never touch a run that another job is working on.
#    If a file in the folder changed within this many minutes, someone is writing.
#    (The writer is an NFS client, so lsof cannot see it. mtime is the only signal.)
QUIET_MIN="${BACKUP_QUIET_MIN:-30}"
#  Runs to exclude by hand, one per line (read if present)
SKIP_LIST="${BACKUP_SKIP_LIST:-/home/frontend/sykim/backup_log/backup_skip.txt}"
#  * Mail queue. This server has no internet, so it cannot send mail itself.
#    Dropped here, the DAQ PC cron (scripts/mailq-send.sh) picks it up every 5 min.
MAILQ_DIR="${BACKUP_MAILQ:-/data/MAILQ}"
MAIL_ENABLE="${BACKUP_MAIL:-1}"
DRYRUN=0

while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run)     DRYRUN=1; shift ;;
		--disks)       MOUNTS_RAW=$2; shift 2 ;;
		--no-mail)     MAIL_ENABLE=0; shift ;;
		--mailq)       MAILQ_DIR=$2; shift 2 ;;
		--no-bwlimit)  BWLIMIT=""; shift ;;
		--split)       SPLIT_MODE=$2; shift 2 ;;
		--margin)      SAFETY_MARGIN=$(( ${2%[gG]} * 1024 * 1024 )); shift 2 ;;   # GB
		--no-split)    SPLIT_MODE=never; shift ;;
		--bwlimit)     BWLIMIT=$2; shift 2 ;;
		-h|--help)     sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

IFS=',' read -r -a DISKS <<< "$MOUNTS_RAW"
[ "${#DISKS[@]}" -ge 1 ] || { echo "ERROR: no disks were given." >&2; exit 2; }

# =====================================================================
#  Disk probes -- the only code that knows if a disk is mounted and how much room is left.
#
#  * BACKUP_TEST_HOOK can replace them. That is how the state machine gets
#    tested without filling a real 2 TB disk -- it fabricates 'disk full' and
#    'disk gone'. (Same kind of escape hatch as DATAFLOW_ALLOW_UNMOUNTED in
#    dataflow.sh.) Never use it in normal operation.
# =====================================================================
disk_is_mounted() { mountpoint -q "$1"; }
disk_df_field()   { df -k "$1" 2>/dev/null | tail -1 | awk -v f="$2" '{print $f+0}'; }
disk_cap_kb()     { disk_df_field "$1" 2; }
disk_used_kb()    { disk_df_field "$1" 3; }
disk_avail_kb()   { disk_df_field "$1" 4; }

# ---------------------------------------------------------------------
#  * Can we actually write to the destination? Mounted does not mean writable.
#
#    On 2026-09-03 this cost an entire run. The disks had just been formatted,
#    so their mount roots were root:root 755 and frontend could not create
#    <mount>/RENE_data_backup. The mkdir error went to /dev/null, so nothing
#    surfaced until the plan for 1,723 folders was built and the first rsync
#    died with "No such file or directory". Worse, the message that followed
#    blamed --split, sending the reader into code that was working fine.
#
#    * -w alone is not enough. Root squash and read-only remounts leave the
#      permission bits looking healthy. You have to create a file to know.
#
#    The reason for failure is left in DEST_ERR.
# ---------------------------------------------------------------------
#  * Read-only probe for the startup summary. It creates nothing.
#    * Do not look at the mount root alone -- leaving the root owned by root and
#      handing over only the destination folder is the normal way to grant this
#      (done that way on 2026-09-03), and the root check then calls a healthy
dest_probe() {           # mount point -> 0 writable / 1 not
	local dest="$1/$DEST_SUBDIR"
	if [ -d "$dest" ]; then [ -w "$dest" ]; else [ -w "$1" ]; fi
}

DEST_ERR=""
dest_ready() {           # mount point
	local dest="$1/$DEST_SUBDIR" t
	DEST_ERR=""
	if ! DEST_ERR=$(mkdir -p "$dest" 2>&1); then
		DEST_ERR="${DEST_ERR:-cannot create the destination folder}"; return 1
	fi
	t="$dest/.write-test.$$"
	if ! DEST_ERR=$(: > "$t" 2>&1); then
		DEST_ERR="${DEST_ERR:-cannot write a file into the destination}"; return 1
	fi
	rm -f "$t" 2>/dev/null
	DEST_ERR=""
	return 0
}

#  Disk identity -- goes in the mail body. Someone has to know which disk to pull.
#  Fills the globals D_DEV, D_UUID, D_MODEL, D_SERIAL.
disk_ident() {
	D_DEV=$(findmnt -no SOURCE "$1" 2>/dev/null)
	D_UUID=""; D_MODEL=""; D_SERIAL=""
	[ -n "$D_DEV" ] || return 0
	D_UUID=$(lsblk -no UUID "$D_DEV" 2>/dev/null | head -1)
	local parent
	parent=$(lsblk -no PKNAME "$D_DEV" 2>/dev/null | head -1)
	if [ -n "$parent" ]; then
		D_MODEL=$(lsblk -dno MODEL  "/dev/$parent" 2>/dev/null | head -1 | sed 's/ *$//')
		D_SERIAL=$(lsblk -dno SERIAL "/dev/$parent" 2>/dev/null | head -1 | sed 's/ *$//')
	fi
	return 0
}

#  * Test override. Replaces only the five functions above.
#    It fabricates 'disk full' and 'disk gone' so the disk-to-disk state machine
#    can be tested without filling a real 2 TB disk (tests/storage-backup.test.sh).
#    * Never use this in normal operation. Unset, it changes nothing.
if [ -n "${BACKUP_TEST_HOOK:-}" ]; then
	if [ -r "$BACKUP_TEST_HOOK" ]; then
		echo "WARNING: test mode -- capacity and mount checks replaced by $BACKUP_TEST_HOOK"
		. "$BACKUP_TEST_HOOK"
	else
		echo "ERROR: cannot read BACKUP_TEST_HOOK: $BACKUP_TEST_HOOK" >&2; exit 2
	fi
fi

# --- KB in units people read (runs span MB to TB) ---------------------
fmt_kb() { awk -v k="$1" 'BEGIN{
   if (k>=1073741824) printf "%.2f TB", k/1073741824;
   else if (k>=1048576) printf "%.1f GB", k/1048576;
   else if (k>=1024)    printf "%.0f MB", k/1024;
   else                 printf "%d KB", k; }'; }

#  seconds -> "3h 20m"
fmt_sec() { awk -v t="$1" 'BEGIN{
	t=int(t+0.5); d=int(t/86400); h=int(t%86400/3600); m=int(t%3600/60)
	if (d>0) printf "%dd %dh", d, h
	else if (h>0) printf "%dh %dm", h, m
	else if (m>0) printf "%dm", m
	else printf "under a minute" }'; }

# --- Folder size (cached). Do not re-run du on a huge folder every time ---
folder_size() {                       # folder name -> KB
	local n=$1 mt sz line
	mt=$(stat -c %Y "$n" 2>/dev/null)
	line=$(grep -m1 "^$n " "$SIZE_CACHE" 2>/dev/null)
	if [ -n "$line" ]; then
		set -- $line
		if [ "$3" = "$mt" ] && [ -n "$2" ]; then echo "$2"; return 0; fi
	fi
	sz=$(du -sk "$n" 2>/dev/null | awk '{print $1}')
	[ -n "$sz" ] || return 1
	{ grep -v "^$n " "$SIZE_CACHE" 2>/dev/null; echo "$n $sz $mt"; } \
		> "$SIZE_CACHE.tmp" 2>/dev/null && mv -f "$SIZE_CACHE.tmp" "$SIZE_CACHE" 2>/dev/null
	echo "$sz"
}

# ---------------------------------------------------------------------
#  * Is another job working on this run? Three things are checked.
#     1) runs excluded by hand
#     2) runs with a file changed in the last $QUIET_MIN minutes (someone writing)
#     3) runs with a leftover rsync fragment (.rsync-partial)
#    If any match, leave it this time. It gets picked up once it goes quiet.
#
#    * The planner and the 'is there work left' check must see this the same way.
#      If they disagree, the plan comes out empty while work still counts as
#      remaining, and the script burns through disks for nothing. So both call
#      this one function.  -> prints the reason as one word on stdout
# ---------------------------------------------------------------------
is_busy() {
	local F=$1
	if [ -r "$SKIP_LIST" ] && grep -qx "$F" "$SKIP_LIST" 2>/dev/null; then
		echo "excluded"; return 0
	fi
	#  * Without -type f the folder's own mtime matches and every run looks busy
	if [ -n "$(find "$F" -type f -newermt "-${QUIET_MIN} minutes" -print -quit 2>/dev/null)" ]; then
		echo "in-use"; return 0
	fi
	if [ -d "$F/.rsync-partial" ] || [ -n "$(find "$F" -maxdepth 2 -name '.rsync-partial' -print -quit 2>/dev/null)" ]; then
		echo "transferring"; return 0
	fi
	return 1
}

# ---------------------------------------------------------------------
#  Is there anything left to move?  * Counted cheaply -- no du.
#  With 1,700 runs, measuring every folder would take minutes per check.
#  All we need here is whether there is any, and how many.
#     REMAIN_N    number of runs with something left to move
#     REMAIN_LIST first 10 names
# ---------------------------------------------------------------------
remaining_work() {
	REMAIN_N=0; REMAIN_LIST=""
	local F
	for F in */; do
		F=${F%/}
		[ -d "$F" ] || continue
		#  An empty shell of a folder has nothing to move
		[ -n "$(find "$F" -type f -print -quit 2>/dev/null)" ] || continue
		is_busy "$F" >/dev/null && continue
		REMAIN_N=$((REMAIN_N+1))
		[ "$REMAIN_N" -le 10 ] && REMAIN_LIST="$REMAIN_LIST $F"
	done
	[ "$REMAIN_N" -gt 0 ]
}

# ---------------------------------------------------------------------
#  Summarise the files as one readable line (category, count, subrun range)
#     understands both FADC_<run>.root.<subrun> and PRD_<run>.<subrun>.root
# ---------------------------------------------------------------------
summarize_files() {      # path to the file list
	awk '{
		p=$0
		if      (p ~ /^Merged\//) c="Merged"
		else if (p ~ /^PRD\//)    c="PRD"
		else if (p ~ /^PNG\//)    c="PNG"
		else if (p ~ /^FADC_/)    c="FADC"
		else if (p ~ /^SADC_/)    c="SADC"
		else                      c="other"
		n[c]++
		s=""
		if      (match(p, /\.root\.[0-9]+$/)) s=substr(p, RSTART+6)
		else if (match(p, /\.[0-9]+\.root$/)) s=substr(p, RSTART+1, RLENGTH-6)
		if (s != "") { v=s+0
			if (!(c in mn) || v<mn[c]) mn[c]=v
			if (!(c in mx) || v>mx[c]) mx[c]=v }
	} END {
		split("FADC SADC Merged PRD PNG other", o, " ")
		out=""
		for (i=1;i<=6;i++) { c=o[i]; if (c in n) {
			t=sprintf("%s %d", c, n[c])
			if (c in mn) t=t sprintf(" (subrun %05d~%05d)", mn[c], mx[c])
			out = (out=="" ? t : out " · " t) } }
		print out
	}' "$1"
}

# =====================================================================
#  Mail -- this server has no internet, so it drops a file (see the header).
#
#  * Backup must continue even when mail does not go out. Nothing that fails
#    here stops the backup: an alert that kills what it watches is worse than
#
#  Format (read by scripts/mailq-send.sh on the DAQ PC)
#      subject: <one line>
#      to: routine
#      body:
#      <everything else>
# =====================================================================
MAIL_SEQ=0
MAIL_QUEUED=0
queue_mail() {           # subject  body-file
	local subj=$1 body=$2 base tmp
	[ "$MAIL_ENABLE" = 1 ] || return 0
	#  * A preview must not reach the outside world. --dry-run promises to change
	#    nothing, and mail going out breaks that promise. (The error paths also go
	#    through finish, so blocking it here covers all of them at once.)
	if [ "$DRYRUN" -eq 1 ]; then
		echo "   (--dry-run: not sending mail -- \"$subj\")"
		return 0
	fi
	mkdir -p "$MAILQ_DIR" 2>/dev/null
	if [ ! -d "$MAILQ_DIR" ] || [ ! -w "$MAILQ_DIR" ]; then
		echo "WARNING: cannot write to the mail queue ($MAILQ_DIR). Continuing without mail."
		echo "[$(date)] WARN cannot write mailq: $MAILQ_DIR" >> "$LOG_FILE"
		return 0
	fi
	MAIL_SEQ=$((MAIL_SEQ+1))
	base="$MAILQ_DIR/$(date +%Y%m%d-%H%M%S)-$$-$MAIL_SEQ"
	tmp="$base.tmp"
	{
		#  A newline in the subject would break the parser. Flatten it to one line.
		printf 'subject: %s\n' "$(printf '%s' "$subj" | tr '\n\r' '  ')"
		printf 'to: routine\n'
		printf 'body:\n'
		cat "$body"
	} > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
	#  * rename is atomic, so the reader never picks up a half-written file.
	mv -f "$tmp" "$base.mail" 2>/dev/null && MAIL_QUEUED=$((MAIL_QUEUED+1))
	return 0
}

#  One disk's identity and capacity as a readable block
disk_block() {           # mount point
	local M=$1
	disk_ident "$M"
	local cap used avail
	cap=$(disk_cap_kb "$M"); used=$(disk_used_kb "$M"); avail=$(disk_avail_kb "$M")
	echo "  Mount    : $M"
	echo "  Device   : ${D_DEV:-(unknown)}"
	echo "  UUID     : ${D_UUID:-(unknown)}"
	[ -n "$D_MODEL" ]  && echo "  Model    : $D_MODEL"
	[ -n "$D_SERIAL" ] && echo "  Serial   : $D_SERIAL"
	if [ "${cap:-0}" -gt 0 ]; then
		echo "  Capacity : $(fmt_kb "$cap")   used $(fmt_kb "$used")  free $(fmt_kb "$avail")  ($((used*100/cap)) % full)"
	fi
	local dest="$M/$DEST_SUBDIR" first last
	if [ -d "$dest" ]; then
		first=$(ls -1 "$dest" 2>/dev/null | sort | head -1)
		last=$(ls -1  "$dest" 2>/dev/null | sort | tail -1)
		[ -n "$first" ] && echo "  Runs on it: $first ~ $last"
	fi
}

# =====================================================================
#  One pass -- fill a single disk.  code8's plan-then-execute lives in here.
#
#  In  : $1 = mount point
#  Out : PASS_RC   0 finished normally, 2 stopped on repeated failures
#                  plus the per-pass counters below
# =====================================================================
run_pass() {
	local MOUNT_POINT=$1
	PASS_RC=0
	N_OK=0; N_SKIP=0; N_FAIL=0; MOVED_KB=0; CONSEC_FAIL=0
	N_PART=0; PART_LIST=""; SKIPPED_LIST=""; TOOBIG_LIST=""; N_TOOBIG=0
	N_BUSY=0; BUSY_LIST=""; P_FILES=0; P_KB=0; P_FULL=0; P_PART=0; SHOWN=0
	PASS_T0=$(date +%s)

	local DEST="$MOUNT_POINT/$DEST_SUBDIR"

	disk_ident "$MOUNT_POINT"
	local UUID=$D_UUID
	local CAP; CAP=$(disk_cap_kb "$MOUNT_POINT")
	echo "[$(date)] === disk $MOUNT_POINT ${D_DEV:-?} UUID=${UUID:-?} pass start ===" >> "$LOG_FILE"

	echo ""
	echo "=========================================================="
	echo "  Disk $MOUNT_POINT  ( ${D_DEV:-?}  UUID=${UUID:-?} )"
	echo "=========================================================="
	echo "Backing up : $SOURCE_PARENT   ->   $DEST"
	echo "   Disk     : $(fmt_kb "$CAP")  (free $(fmt_kb "$(disk_avail_kb "$MOUNT_POINT")"))"
	echo "   Verify   : count+bytes (must pass before anything is deleted)   speed limit: ${BWLIMIT:-none}"

	#  * Clear the plan files between passes.
	#    A leftover list.<run> from the previous disk would be read as this pass's
	#    own, and files that were never sent would be treated as verified and
	#    deleted. This is the most dangerous line in the whole change.
	rm -f "$PLANDIR"/plan.tsv "$PLANDIR"/list.* "$PLANDIR"/sizes.* \
	      "$PLANDIR"/cur.* "$PLANDIR"/del.* "$PLANDIR"/chg.* 2>/dev/null
	: > "$PLANDIR/plan.tsv"

	# -----------------------------------------------------------------
	#  Step 1 -- plan. Work out what fits on this disk before moving anything, so
	#  a person can see the target and the time it will take before it starts.
	# -----------------------------------------------------------------
	local SIM; SIM=$(disk_avail_kb "$MOUNT_POINT")
	local FOLDER F USABLE SZ NF B TOT WHY FITS_EMPTY DO_SPLIT

	echo "Working out what fits on this disk... (may take minutes with many folders)"
	for FOLDER in */; do
		[ -e "$FOLDER" ] || continue
		F=${FOLDER%/}
		USABLE=$((SIM - SAFETY_MARGIN))
		[ "$USABLE" -lt "$MIN_USEFUL" ] && break

		if WHY=$(is_busy "$F"); then
			N_BUSY=$((N_BUSY+1)); BUSY_LIST="$BUSY_LIST $F($WHY)"; continue
		fi

		SZ=$(folder_size "$F") || continue

		if [ "$SZ" -lt "$USABLE" ]; then
			( cd "$F" && find . -type f -printf '%s\t%P\n' 2>/dev/null | sort -t"$(printf '\t')" -k2 ) \
				> "$PLANDIR/sizes.$F"
			cut -f2- "$PLANDIR/sizes.$F" > "$PLANDIR/list.$F"
			NF=$(wc -l < "$PLANDIR/list.$F")
			printf '%s\tfull\t%s\t%s\n' "$F" "$NF" "$SZ" >> "$PLANDIR/plan.tsv"
			SIM=$((SIM - SZ)); P_FILES=$((P_FILES+NF)); P_KB=$((P_KB+SZ)); P_FULL=$((P_FULL+1))
			continue
		fi

		#  It does not fit. Slice it?
		FITS_EMPTY=1
		[ "$SZ" -ge "$((CAP - SAFETY_MARGIN))" ] && FITS_EMPTY=0
		DO_SPLIT=0
		case "$SPLIT_MODE" in
			always) DO_SPLIT=1 ;;
			auto)   [ "$FITS_EMPTY" -eq 0 ] && DO_SPLIT=1 ;;
		esac

		if [ "$DO_SPLIT" -eq 0 ]; then
			N_SKIP=$((N_SKIP+1))
			if [ "$FITS_EMPTY" -eq 0 ]; then N_TOOBIG=$((N_TOOBIG+1)); TOOBIG_LIST="$TOOBIG_LIST $F"
			else SKIPPED_LIST="$SKIPPED_LIST $F"; fi
			continue
		fi

		#  Build a list of just the files that fit (step 2 uses this list as-is)
		( cd "$F" && find . -type f -printf '%s\t%P\n' 2>/dev/null | sort -t"$(printf '\t')" -k2 ) \
			> "$PLANDIR/sizes.$F"
		awk -F'\t' -v cap=$(( USABLE * 1024 )) '{ if (s + $1 <= cap) { s += $1; print $2 } }' \
			"$PLANDIR/sizes.$F" > "$PLANDIR/list.$F"
		NF=$(wc -l < "$PLANDIR/list.$F")
		if [ "$NF" -eq 0 ]; then
			N_SKIP=$((N_SKIP+1)); SKIPPED_LIST="$SKIPPED_LIST $F"
			rm -f "$PLANDIR/list.$F" "$PLANDIR/sizes.$F"; continue
		fi
		B=$(awk -F'\t' -v cap=$(( USABLE * 1024 )) '{ if (s + $1 <= cap) s += $1 } END{ print s+0 }' \
			"$PLANDIR/sizes.$F")
		TOT=$(wc -l < "$PLANDIR/sizes.$F")
		printf '%s\tpart\t%s\t%s\t%s\n' "$F" "$NF" "$((B/1024))" "$TOT" >> "$PLANDIR/plan.tsv"
		SIM=$((SIM - B/1024)); P_FILES=$((P_FILES+NF)); P_KB=$((P_KB+B/1024)); P_PART=$((P_PART+1))
	done

	# --- show the plan -----------------------------------------------
	echo ""
	echo "  To be written to this disk"
	echo "  ----------------------------------------------------------"
	if [ ! -s "$PLANDIR/plan.tsv" ]; then
		echo "  Nothing to write."
		echo "   - free on disk : $(fmt_kb "$(disk_avail_kb "$MOUNT_POINT")") (needs a $(fmt_kb "$SAFETY_MARGIN") safety margin)"
		[ "$N_SKIP" -gt 0 ] && echo "   - runs skipped for lack of room : $N_SKIP"
		if [ "$N_BUSY" -gt 0 ]; then
			echo "   - runs left alone because another job is using them : $N_BUSY"
			echo "$BUSY_LIST" | tr ' ' '\n' | grep -v '^$' | head -10 | sed 's/^/       /'
			echo "     Files changed within the last ${QUIET_MIN} min. They will be picked up once quiet."
		fi
		return 0
	fi
	local KB MODE
	while IFS=$'\t' read -r F MODE NF KB TOT; do
		SHOWN=$((SHOWN+1))
		if [ "$SHOWN" -le 25 ]; then
			if [ "$MODE" = part ]; then
				printf '  run %s  [part]   %s / %s files  %s\n' "$F" "$NF" "$TOT" "$(fmt_kb "$KB")"
			else
				printf '  run %s  [whole]  %s files  %s\n' "$F" "$NF" "$(fmt_kb "$KB")"
			fi
			printf '       %s\n' "$(summarize_files "$PLANDIR/list.$F")"
		fi
	done < "$PLANDIR/plan.tsv"
	[ "$SHOWN" -gt 25 ] && echo "  ... and $((SHOWN-25)) more runs"
	echo "  ----------------------------------------------------------"
	echo "  Total    : $SHOWN runs (whole $P_FULL, part $P_PART) · $P_FILES files · $(fmt_kb "$P_KB")"
	echo "  Disk     : $(fmt_kb "$P_KB") of $(fmt_kb "$CAP") newly written -> $(fmt_kb "$SIM") free when done"
	local RATE_KBPS ETA
	if [ -n "$BWLIMIT" ]; then
		RATE_KBPS=$(awk -v b="$BWLIMIT" 'BEGIN{ v=b+0; if (b ~ /[mM]/) v=v*1024; else if (b ~ /[gG]/) v=v*1024*1024; print v }')
	else
		RATE_KBPS=80000        # rough guess when unlimited (about 80 MB/s)
	fi
	ETA=$(( P_KB / (RATE_KBPS>0 ? RATE_KBPS : 1) ))
	echo "  Speed    : ${BWLIMIT:-unlimited} -> about $(fmt_sec "$ETA") (verification is extra)"
	[ "$N_SKIP" -gt 0 ] && echo "  Skipped  : $N_SKIP (no room on this disk; they go on the next one)"
	if [ "$N_BUSY" -gt 0 ]; then
		echo "  Paused   : $N_BUSY runs left alone because another job is using them"
		echo "$BUSY_LIST" | tr ' ' '\n' | grep -v '^$' | head -10 | sed 's/^/       /'
		[ "$N_BUSY" -gt 10 ] && echo "       ... and $((N_BUSY-10)) more"
	fi
	echo "=========================================================="
	echo ""

	[ "$DRYRUN" -eq 1 ] && return 0

	# -----------------------------------------------------------------
	#  Step 2 -- execute. Follows the plan above exactly.
	# -----------------------------------------------------------------
	local T0 DONE_KB IDX FOLDER_NAME RC WANT_N WANT_B GOT NCHG LEFT EL REMAINSEC RSOPT
	T0=$(date +%s); DONE_KB=0; IDX=0
	while IFS=$'\t' read -r FOLDER_NAME MODE NF KB TOT; do
		IDX=$((IDX+1))
		echo "----------------------------------------------------------"
		if [ "$MODE" = part ]; then
			echo "[$IDX/$SHOWN] $FOLDER_NAME  (part $NF / $TOT files, $(fmt_kb "$KB"))"
		else
			echo "[$IDX/$SHOWN] $FOLDER_NAME  ($NF files, $(fmt_kb "$KB"))"
		fi

		echo "[$(date)]  $FOLDER_NAME transfer start ($MODE) -> $MOUNT_POINT" >> "$LOG_FILE"
		RSOPT=(-a --partial-dir=.rsync-partial --info=progress2 --files-from="$PLANDIR/list.$FOLDER_NAME")
		[ -n "$BWLIMIT" ] && RSOPT+=(--bwlimit="$BWLIMIT")
		#  * A silent failure here makes rsync die with an unrelated error. Say why.
		if ! MKERR=$(mkdir -p "$DEST/$FOLDER_NAME" 2>&1); then
			N_FAIL=$((N_FAIL+1)); CONSEC_FAIL=$((CONSEC_FAIL+1))
			echo "FAILED $FOLDER_NAME : cannot create the destination folder -- $MKERR"
			echo "[$(date)] FAIL mkdir $DEST/$FOLDER_NAME : $MKERR" >> "$LOG_FILE"
			continue
		fi
		#  * --remove-source-files is not used. Deletion happens after verification.
		rsync "${RSOPT[@]}" "$FOLDER_NAME/" "$DEST/$FOLDER_NAME/" 2>>"$LOG_FILE"
		RC=$?

		if [ "$RC" -ne 0 ]; then
			N_FAIL=$((N_FAIL+1)); CONSEC_FAIL=$((CONSEC_FAIL+1))
			echo "FAILED $FOLDER_NAME transfer (rc=$RC). * The source is left untouched."
			echo "[$(date)] FAIL rsync $FOLDER_NAME rc=$RC" >> "$LOG_FILE"
			if [ "$CONSEC_FAIL" -ge "$MAX_CONSEC_FAIL" ]; then
				echo ""
				echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
				echo "WARNING: ${CONSEC_FAIL} failures in a row. The disk may have dropped off the bus."
				echo "   Check :  ls /dev/sd*  ·  dmesg -T | tail -30  ·  df -h $MOUNT_POINT"
				echo "   (df can look fine while the device is gone -- a ghost mount)"
				echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
				echo "[$(date)] stopped after ${CONSEC_FAIL} consecutive failures" >> "$LOG_FILE"
				PASS_RC=2
				break
			fi
			continue
		fi

		#  Verify: is every listed file at the destination with the same size?
		WANT_N=$(wc -l < "$PLANDIR/list.$FOLDER_NAME")
		WANT_B=$( cd "$FOLDER_NAME" && tr '\n' '\0' < "$PLANDIR/list.$FOLDER_NAME" \
		          | xargs -0 stat -c %s 2>/dev/null | awk '{t+=$1} END{print t+0}' )
		GOT=$( cd "$DEST/$FOLDER_NAME" && tr '\n' '\0' < "$PLANDIR/list.$FOLDER_NAME" \
		       | xargs -0 stat -c %s 2>/dev/null | awk '{c++; t+=$1} END{printf "%d %d", c+0, t+0}' )
		set -- $GOT
		if [ "${1:-0}" -ne "$WANT_N" ] || [ "${2:-0}" -ne "${WANT_B:-0}" ]; then
			N_FAIL=$((N_FAIL+1)); CONSEC_FAIL=$((CONSEC_FAIL+1))
			echo "FAILED $FOLDER_NAME verification (destination $1 files $2 B / sent $WANT_N files $WANT_B B). * Nothing deleted."
			echo "[$(date)] FAIL verify $FOLDER_NAME" >> "$LOG_FILE"
			continue
		fi

		#  Record which piece went to which disk (only meaningful for a part)
		if [ "$MODE" = part ]; then
			{
				echo "# run $FOLDER_NAME  part  $(date '+%F %T')  UUID=$UUID  files=$WANT_N bytes=$WANT_B"
				echo "# $(head -1 "$PLANDIR/list.$FOLDER_NAME") ~ $(tail -1 "$PLANDIR/list.$FOLDER_NAME")"
				cat "$PLANDIR/list.$FOLDER_NAME"
			} >> "$DEST/$FOLDER_NAME/.part_manifest.txt" 2>/dev/null
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$FOLDER_NAME" "$UUID" "$(date '+%F %T')" \
				"$WANT_N" "$WANT_B" "$(head -1 "$PLANDIR/list.$FOLDER_NAME")" \
				"$(tail -1 "$PLANDIR/list.$FOLDER_NAME")" >> "$PARTS_INDEX" 2>/dev/null
		fi

		#  * Check the source once more, right before deleting.
		#    Hours pass between building the plan and finishing the transfer, and
		#    another job may have rewritten or added files in the same run. Delete only
		#    files whose size still matches the plan. Keep the rest and say so.
		( cd "$FOLDER_NAME" && tr '\n' '\0' < "$PLANDIR/list.$FOLDER_NAME" \
		  | xargs -0 stat --printf='%s\t%n\n' 2>/dev/null ) > "$PLANDIR/cur.$FOLDER_NAME"
		awk -F'\t' 'NR==FNR { want[$2]=$1; next }
		            { if (($2 in want) && want[$2]==$1) print $2; else print $2 > "/dev/stderr" }' \
			"$PLANDIR/sizes.$FOLDER_NAME" "$PLANDIR/cur.$FOLDER_NAME" \
			> "$PLANDIR/del.$FOLDER_NAME" 2> "$PLANDIR/chg.$FOLDER_NAME"
		NCHG=$(wc -l < "$PLANDIR/chg.$FOLDER_NAME")
		if [ "$NCHG" -gt 0 ]; then
			echo "WARNING: $FOLDER_NAME : $NCHG files changed during the transfer and were kept (another job touched them)"
			echo "[$(date)] WARN $FOLDER_NAME kept $NCHG changed files" >> "$LOG_FILE"
			head -5 "$PLANDIR/chg.$FOLDER_NAME" | sed 's/^/       /'
		fi

		#  Delete only what passed verification and did not change since
		( cd "$FOLDER_NAME" && tr '\n' '\0' < "$PLANDIR/del.$FOLDER_NAME" | xargs -0 rm -f 2>/dev/null )
		find "$FOLDER_NAME" -mindepth 1 -type d -empty -delete 2>/dev/null
		CONSEC_FAIL=0; MOVED_KB=$((MOVED_KB+KB)); DONE_KB=$((DONE_KB+KB))

		LEFT=$(find "$FOLDER_NAME" -type f 2>/dev/null | wc -l)
		if [ "$LEFT" -eq 0 ]; then
			rm -rf "$FOLDER_NAME"
			N_OK=$((N_OK+1))
			echo "OK $FOLDER_NAME complete and removed from the server"
			echo "[$(date)] $FOLDER_NAME complete and removed from the server." >> "$LOG_FILE"
		else
			N_PART=$((N_PART+1)); PART_LIST="$PART_LIST $FOLDER_NAME"
			echo "$FOLDER_NAME : this disk's share is done. $LEFT files left -- continuing on the next disk"
			echo "[$(date)] $FOLDER_NAME partial backup $WANT_N files ($LEFT left)" >> "$LOG_FILE"
		fi

		EL=$(( $(date +%s) - T0 ))
		if [ "$DONE_KB" -gt 0 ] && [ "$EL" -gt 0 ]; then
			REMAINSEC=$(( (P_KB - DONE_KB) * EL / DONE_KB ))
			printf 'progress %d%% (%s / %s) · about %s left · %s free on disk\n' \
				$(( DONE_KB * 100 / (P_KB>0?P_KB:1) )) "$(fmt_kb "$DONE_KB")" "$(fmt_kb "$P_KB")" \
				"$(fmt_sec "$REMAINSEC")" "$(fmt_kb "$(disk_avail_kb "$MOUNT_POINT")")"
		fi
	done < "$PLANDIR/plan.tsv"

	echo ""
	echo "  Disk $MOUNT_POINT pass result"
	echo "  moved $N_OK · spanned $N_PART · $(fmt_kb "$MOVED_KB") · skipped $N_SKIP · failed $N_FAIL"
	{
		echo " back up status = HDD UUID = $UUID , Back up date = $(date)"
		echo " moved $N_OK / skipped $N_SKIP / failed $N_FAIL"
		[ -n "$SKIPPED_LIST" ] && echo " skipped:$SKIPPED_LIST"
	} >> "$LOG_FILE"
	return 0
}

# =====================================================================
#  Mail body -- every mail gets this tail.
#  Someone woken at 3 a.m. has to be able to act on this alone.
# =====================================================================
body_tail() {
	echo "-- Per-disk result -------------------------------------"
	if [ -s "$PLANDIR/disks.txt" ]; then
		cat "$PLANDIR/disks.txt"
	else
		echo "  (no disk was written in this session)"
	fi
	echo ""
	echo "-- Work left on the server -----------------------------"
	if [ "${REMAIN_N:--1}" -lt 0 ]; then
		echo "  (not checked)"
	elif [ "$REMAIN_N" -eq 0 ]; then
		echo "  Nothing left to move."
	else
		echo "  Runs with something left to move : $REMAIN_N"
		echo "  First 10 :$REMAIN_LIST"
	fi
	echo ""
	echo "-- Log for this session (last 40 lines) ----------------"
	tail -n "+$((LOG_MARK+1))" "$LOG_FILE" 2>/dev/null | tail -40
	echo ""
	echo "─────────────────────────────────────────────────────────"
	echo "  Host   : $(hostname)    Time : $(date '+%F %T')"
	echo "  Source : $SOURCE_PARENT"
	echo "  Log    : $LOG_FILE"
	echo "  Parts  : $PARTS_INDEX  (record of runs split across disks)"
	echo "  Script : $0"
}

#  Exit -- called after the reason is already on screen. Body preamble on stdin.
finish() {               # exit-code  subject
	local code=$1 subj=$2 bf="$PLANDIR/mail.body"
	{ cat; echo ""; body_tail; } > "$bf" 2>/dev/null
	queue_mail "$subj" "$bf"
	if [ "$MAIL_ENABLE" = 1 ]; then
		if [ "$MAIL_QUEUED" -gt 0 ]; then
			echo "Queued $MAIL_QUEUED mail(s) in $MAILQ_DIR."
			echo "   The DAQ PC cron sends them within 5 minutes."
		fi
	fi
	echo "[$(date)] exit code=$code : $subj" >> "$LOG_FILE"
	exit "$code"
}

# =====================================================================
#  Start -- checks and locking
# =====================================================================
[ -t 1 ] && clear
echo "=========================================================="
echo "        RENE storage backup  (multi-disk sequential mode)"
echo "     You are on the STORAGE SERVER, not the DAQ PC.             "
echo "=========================================================="
echo "  Disk order : ${DISKS[*]}"
[ "$DRYRUN" -eq 1 ] && echo "NOTE --dry-run : nothing will be moved or deleted."

[ -d "$SOURCE_PARENT" ] || { echo "ERROR: $SOURCE_PARENT does not exist."; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$SIZE_CACHE")" 2>/dev/null
touch "$SIZE_CACHE" "$LOG_FILE" 2>/dev/null

#  * Two of these at once would move the same files twice and delete them twice.
#
#  * The lock alone is not enough: an older version someone started by hand does
#    not hold it. On 2026-09-02 one was running from 01:48, went unnoticed, and a
#    second was started at 02:24 -- 30+50 = 80 MB/s onto the same USB disk, which
#    is exactly the rate at which this disk dropped off the bus on 08-27. So the
#    process list is checked as well.
#
#  * pgrep -f matches the whole command line, so our own lineage matches too.
#    Excluding descendants is not enough -- both directions have to go.
#
#      descendant : a $(...) subshell. Walking its parents reaches $$
#      ancestor   : the shell that started us. If this script's path sits in
#                   that shell's command line (as it does when sent over ssh),
#                   it matches. In testing on 2026-09-03 this alone stopped the
#                   script from ever running. Drop any pid in our ancestor list.
my_ancestors() {
	local anc=$$ i out=""
	for i in 1 2 3 4 5 6 7 8; do
		anc=$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')
		{ [ -n "$anc" ] && [ "$anc" != 0 ]; } || break
		out="$out $anc"
	done
	echo "$out"
}
other_backup() {
	local p anc i found mine args
	mine=" $(my_ancestors) "
	for p in $(pgrep -f 'data_backup_simple_code[0-9]*\.sh|storage-backup\.sh' 2>/dev/null); do
		[ "$p" = "$$" ] && continue
		case "$mine" in *" $p "*) continue ;; esac      # our ancestor
		#  * Something already dead is not a running backup.
		#    $( ) makes bash fork a short-lived subshell that inherits this script's
		#    command line. pgrep catches it, but by the time we look it is gone, so the
		#    parent walk comes back empty and it gets mistaken for someone else's
		#    backup -- which means this never runs at all (that is exactly what happened
		#    in testing on 2026-09-03).
		args=$(ps -o args= -p "$p" 2>/dev/null)
		[ -n "$args" ] || continue
		found=0; anc=$p
		for i in 1 2 3 4 5 6; do
			anc=$(ps -o ppid= -p "$anc" 2>/dev/null | tr -d ' ')
			{ [ -n "$anc" ] && [ "$anc" != 0 ]; } || break
			[ "$anc" = "$$" ] && { found=1; break; }
		done
		[ "$found" = 1 ] && continue                    # our descendant
		echo "$p"; return 0
	done
	return 1
}
if OTHER=$(other_backup); then
	echo "ERROR: a backup is already running (pid $OTHER)."
	echo "   $(ps -o lstart=,args= -p "$OTHER" 2>/dev/null | sed 's/^ *//')"
	echo "   Wait for it to finish. Two of them on one disk get the free-space"
	echo "   arithmetic wrong, and the combined rate can knock the USB disk off."
	exit 1
fi

mkdir -p "$(dirname "$LOCK")" 2>/dev/null
exec 9>"$LOCK" || exit 1
if ! flock -n 9; then
	echo "ERROR: a backup is already running (lock $LOCK)."
	exit 1
fi

cd "$SOURCE_PARENT" || exit 1

PLANDIR=$(mktemp -d) || exit 1
trap 'rm -rf "$PLANDIR"' EXIT
: > "$PLANDIR/disks.txt"

SESSION_T0=$(date +%s)
LOG_MARK=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
echo "Data backup start, by sykim, $(date) " >> "$LOG_FILE"
echo "[$(date)] session start disks=${DISKS[*]} bwlimit=${BWLIMIT:-none} split=$SPLIT_MODE" >> "$LOG_FILE"

#  * Show the state of every disk up front. Nobody should start an eight-hour
#    job blind, and an unusable disk should be obvious before it wastes time.
echo ""
echo "  Disks to use"
for M in "${DISKS[@]}"; do
	if ! disk_is_mounted "$M"; then
		printf '    %-16s NOT MOUNTED\n' "$M"; continue
	fi
	disk_ident "$M"
	printf '    %-16s %s  free %s  %s\n' "$M" "${D_DEV:-?}" \
		"$(fmt_kb "$(disk_avail_kb "$M")")" \
		"$( dest_probe "$M" && echo 'writable' || echo 'NOT WRITABLE -- see below' )"
	dest_probe "$M" || {
		printf '                     sudo mkdir -p %s/%s\n' "$M" "$DEST_SUBDIR"
		printf '                     sudo chown %s:%s %s/%s\n' "$(id -un)" "$(id -gn)" "$M" "$DEST_SUBDIR"
	}
done
echo ""

TOT_OK=0; TOT_PARTRUN=0; TOT_FAIL=0; TOT_KB=0; TOT_SKIP=0
REMAIN_N=-1; REMAIN_LIST=""
USED_DISKS=""; LAST_DISK=""; OUTCOME=""

# =====================================================================
#  Walk the disks in order -- this loop is the heart of the script.
# =====================================================================
for IDXD in "${!DISKS[@]}"; do
	M=${DISKS[$IDXD]}
	FIRST=0; [ "$IDXD" -eq 0 ] && FIRST=1

	# --- is it mounted? ---------------------------------------------
	if ! disk_is_mounted "$M"; then
		if [ "$FIRST" -eq 1 ]; then
			echo "ERROR: $M is not mounted."
			finish 1 "Storage backup failed -- first disk $M is not mounted" <<EOF
The backup could not start.

  First disk $M is not mounted.

* df can look fine while the device is gone -- a ghost mount.
  Check :  ls /dev/sd*  ·  lsblk  ·  findmnt $M  ·  dmesg -T | tail -30
  Mount :  sudo mount UUID=<that disk UUID> $M
EOF
		fi
		#  * This is the check that was asked for -- the previous disk filled and this
		echo "ERROR: the next disk $M is not mounted. Stopping here."
		finish 1 "Storage backup stopped -- next disk $M is not mounted" <<EOF
The previous disk filled up and $M was next, but that disk is not mounted.
Data that has not been moved yet is still on the server.

  Disk just filled : $LAST_DISK
  Next disk        : $M   <- not mounted

* df can look fine while the device is gone -- a ghost mount.
  Check :  ls /dev/sd*  ·  lsblk  ·  findmnt $M  ·  dmesg -T | tail -30
  Mount :  sudo mount UUID=<that disk UUID> $M
  Then run the same command again and it continues where it stopped.
EOF
	fi

	# --- * can we actually write to it? ------------------------------
	#  Checking only the mount means dying at the first rsync, plan already built.
	if ! dest_ready "$M"; then
		echo "ERROR: cannot write to $M -- $DEST_ERR"
		finish 1 "Storage backup stopped -- cannot write to $M" <<EOF
$M is mounted, but the backup folder cannot be created or written.

  Disk        : $M   (${D_DEV:-?}  UUID=${D_UUID:-?})
  Destination : $M/$DEST_SUBDIR
  Reason      : $DEST_ERR

* On a freshly formatted disk this is almost always permissions. If the mount
  point root is owned by root, an ordinary account cannot create a folder in it.

  Check :  ls -ld $M
  Fix   :  sudo chown $(id -un):$(id -gn) $M
           (or  sudo mkdir -p $M/$DEST_SUBDIR && sudo chown $(id -un):$(id -gn) $M/$DEST_SUBDIR )

  If it was remounted read-only :  mount | grep $M   ·  dmesg -T | tail -30
EOF
	fi

	# --- is there room? ---------------------------------------------
	AVAIL=$(disk_avail_kb "$M")
	if [ "$((AVAIL - SAFETY_MARGIN))" -lt "$MIN_USEFUL" ]; then
		if [ "$FIRST" -eq 1 ]; then
			#  A first disk that is already full is not an error -- a previous session
			#  filled it. Just move on to the next one.
			echo "NOTE $M is already full (free $(fmt_kb "$AVAIL")). Moving on to the next disk."
			echo "[$(date)] $M already full -> next disk" >> "$LOG_FILE"
			LAST_DISK=$M
			continue
		fi
		#  * The other check that was asked for -- we moved on and this one is full too.
		echo "ERROR: the next disk $M has no free space. Stopping here."
		finish 1 "Storage backup stopped -- next disk $M has no free space" <<EOF
The previous disk filled up and $M was next, but that disk has no room either.
Data that has not been moved yet is still on the server.

  Disk just filled : $LAST_DISK
  Next disk        : $M
      free $(fmt_kb "$AVAIL")  /  minimum needed $(fmt_kb "$((SAFETY_MARGIN + MIN_USEFUL))")
      (safety margin $(fmt_kb "$SAFETY_MARGIN") + minimum useful $(fmt_kb "$MIN_USEFUL"))

* Swap in a fresh disk and run the same command; it continues where it stopped.
  The full disk can be stored as it is -- everything on it passed verification.
EOF
	fi

	# --- fill this disk ---------------------------------------------
	LAST_DISK=$M
	USED_DISKS="$USED_DISKS $M"
	run_pass "$M"
	PASS_EL=$(( $(date +%s) - PASS_T0 ))
	TOT_OK=$((TOT_OK + N_OK)); TOT_PARTRUN=$((TOT_PARTRUN + N_PART))
	TOT_FAIL=$((TOT_FAIL + N_FAIL)); TOT_KB=$((TOT_KB + MOVED_KB))
	TOT_SKIP=$((TOT_SKIP + N_SKIP))
	{
		echo "[$M]"
		disk_block "$M"
		echo "  This pass: moved $N_OK · spanned $N_PART · failed $N_FAIL · $(fmt_kb "$MOVED_KB") · took $(fmt_sec "$PASS_EL")"
		echo ""
	} >> "$PLANDIR/disks.txt"

	#  Stopped on repeated failures -- suspect the hardware. Do not move on.
	if [ "$PASS_RC" -eq 2 ]; then
		remaining_work; :
		OUTCOME=hwfail
		finish 1 "Storage backup stopped -- $M transfers failed ${MAX_CONSEC_FAIL} times in a row" <<EOF
Writing to $M failed ${MAX_CONSEC_FAIL} times in a row, so the backup stopped.
* The external disk may have dropped off the bus (same symptom as 2026-08-27 / 08-28).

  Check :  ls /dev/sd*        does that device still exist at all
          dmesg -T | tail -30    'device offline' followed by 'Attached SCSI disk'
                                 means it dropped and came back under a new name
          df -h $M           * df can look fine on a ghost mount

* Nothing was deleted from the source. Only verified files are ever deleted,
  so this failure lost no data.
EOF
	fi

	#  --- pass finished. What next? ---------------------------------
	if [ "$DRYRUN" -eq 1 ]; then
		echo ""
		echo "NOTE --dry-run: only the first disk was planned."
		echo "   In a real run it continues to the next disk once this one fills."
		OUTCOME=dryrun
		break
	fi

	if ! remaining_work; then
		OUTCOME=done
		break
	fi

	AVAIL=$(disk_avail_kb "$M")
	if [ "$((AVAIL - SAFETY_MARGIN))" -lt "$MIN_USEFUL" ]; then
		#  The disk is full. Move on to the next one.
		NEXT=${DISKS[$((IDXD+1))]:-}
		echo ""
		echo "$M is full (free $(fmt_kb "$AVAIL")). $REMAIN_N runs still to move."
		if [ -n "$NEXT" ]; then
			echo "   -> continuing on the next disk $NEXT."
			echo "[$(date)] $M full -> continuing on $NEXT (runs left $REMAIN_N)" >> "$LOG_FILE"
			#  * Someone has to be able to read this mail and go pull the disk, so
			#    one goes out at exactly this moment.
			{
				echo "$M is full; continuing on the next disk $NEXT."
				echo "This disk can now be pulled and stored -- everything on it passed verification."
				echo ""
				body_tail
			} > "$PLANDIR/mail.body"
			queue_mail "Storage backup -- $M full, continuing on $NEXT" "$PLANDIR/mail.body"
			continue
		fi
		OUTCOME=nodisk
		break
	fi

	#  The disk is not full but nothing moved. The reason matters --
	#  * a failed transfer and nothing-that-fits need completely different actions.
	if [ "$N_FAIL" -gt 0 ]; then
		OUTCOME=xferfail
		break
	fi
	OUTCOME=stuck
	break
done

# =====================================================================
#  Wrap up
# =====================================================================
[ "${REMAIN_N:--1}" -lt 0 ] && { remaining_work || true; }
SESSION_EL=$(( $(date +%s) - SESSION_T0 ))

echo ""
echo "=========================================================="
echo "  Session total : moved $TOT_OK · spanned $TOT_PARTRUN · $(fmt_kb "$TOT_KB")"
echo "                  skipped $TOT_SKIP · failed $TOT_FAIL · took $(fmt_sec "$SESSION_EL")"
echo "  Disks used    :${USED_DISKS:- (none)}"
echo "=========================================================="
echo "Data backup done, by sykim, $(date) " >> "$LOG_FILE"

case "$OUTCOME" in
dryrun)
	echo "NOTE nothing was moved or deleted."
	exit 0
	;;
done)
	echo "Backup finished safely. Nothing left to move." | tee -a "$LOG_FILE"
	finish 0 "Storage backup complete -- moved $TOT_OK · $(fmt_kb "$TOT_KB")" <<EOF
The backup finished normally. There is nothing left to move on the server.

  Runs moved   : $TOT_OK
  Runs spanning disks : $TOT_PARTRUN
  Total size   : $(fmt_kb "$TOT_KB")
  Failures     : $TOT_FAIL
  Elapsed      : $(fmt_sec "$SESSION_EL")
  Disks used   :${USED_DISKS:- (none)}
EOF
	;;
nodisk)
	echo "WARNING: every listed disk is full and $REMAIN_N runs still need moving."
	echo "   Swap in a fresh disk and run the same command to continue."
	finish 3 "Storage backup -- all disks full, swap needed ($REMAIN_N runs left)" <<EOF
Every listed disk (${DISKS[*]}) is full, and data still needs moving.

  Runs moved   : $TOT_OK   ($(fmt_kb "$TOT_KB"))
  Runs left    : $REMAIN_N
  Elapsed      : $(fmt_sec "$SESSION_EL")

* Swap a full disk for a fresh one and run the same command; it continues
  where it stopped. Everything on the disk you pull passed verification
EOF
	;;
xferfail)
	echo "ERROR: transfers failed and nothing progressed (this pass: $N_FAIL failures, $REMAIN_N runs left)."
	echo "   * Nothing was deleted from the source. The reason is on the FAIL lines:"
	echo "     grep FAIL $LOG_FILE | tail -20"
	finish 1 "Storage backup stopped -- transfers failed ($N_FAIL failures)" <<EOF
There was room on the disk, but transfers failed and nothing progressed.

  Last disk    : $LAST_DISK   (free $(fmt_kb "$(disk_avail_kb "$LAST_DISK")"))
  This pass    : $N_FAIL failures · $N_OK moved
  Runs left    : $REMAIN_N

* Nothing at all was deleted from the source. Only verified files are deleted.

Where to look :
  grep FAIL $LOG_FILE | tail -20

Common causes :
  mkdir ... Permission denied          no permission to create the destination
        -> ls -ld $LAST_DISK  ·  sudo chown $(id -un):$(id -gn) $LAST_DISK
  No such file or directory            destination parent missing (usually the same cause)
  Input/output error / rc=23           * the disk may have dropped off the bus
        -> ls /dev/sd*  ·  dmesg -T | tail -30
EOF
	;;
stuck)
	echo "WARNING: there was room on the disk but nothing more could be placed ($REMAIN_N runs left)."
	if [ "$N_TOOBIG" -gt 0 ] || [ "$SPLIT_MODE" != always ]; then
		echo "   Split mode is --split $SPLIT_MODE. A run larger than the disk needs"
		echo "   --split always (the default) to be spread across disks."
	else
		echo "   The plan came out empty. The remaining runs may all be in use by"
		echo "   another job, or their size could not be measured."
		echo "   Check :  $0 --dry-run"
	fi
	finish 3 "Storage backup -- nothing more could be placed ($REMAIN_N runs left)" <<EOF
There was room on the disk but nothing more could be placed. Swapping disks
would not help, so it stopped here rather than burning through them.

  Last disk    : $LAST_DISK   (free $(fmt_kb "$(disk_avail_kb "$LAST_DISK")"))
  Runs left    : $REMAIN_N
  This pass    : moved $N_OK · skipped $N_SKIP (larger than the disk: $N_TOOBIG) · in use $N_BUSY
  Split mode   : --split $SPLIT_MODE

* You can see what it tried to place with (this changes nothing):
  $0 --dry-run
EOF
	;;
*)
	#  Disk list empty, or the first disk is already full and there is no next one
	if [ "${REMAIN_N:-0}" -gt 0 ]; then
		echo "WARNING: no usable disk. $REMAIN_N runs still need moving."
		finish 3 "Storage backup -- no usable disk ($REMAIN_N runs left)" <<EOF
Every listed disk (${DISKS[*]}) is full, so nothing could be placed at all.

  Runs left : $REMAIN_N

* Swap in a fresh disk and run the same command again.
EOF
	fi
	echo "Nothing to move." | tee -a "$LOG_FILE"
	finish 0 "Storage backup -- nothing to move" <<EOF
The backup ran but there was nothing to move. This is normal.
EOF
	;;
esac
