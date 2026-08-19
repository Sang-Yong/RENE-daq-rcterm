# -*- coding: utf-8 -*-
"""Comprehensive deck (English) — architecture / what changed / measurements / next."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deck import *
from pptx.enum.text import PP_ALIGN

SANS_EN = "Segoe UI"
d = Deck(sans=SANS_EN)

d.title("RENE / CUPDAQ",
        "A text run control\nand an unattended DAQ",
        "It began as a rewrite of a GUI run control. It ended as one chain — taking data,\n"
        "processing it, backing it up, watching itself, and calling a human when it cannot cope.",
        ["Yeong-Gwang site  ·  Rocky Linux 9.8  ·  ROOT 6.28/04  ·  GCC 11.5.0",
         "August 2026  ·  runs 4280-4302  ·  four clean 24-hour rotations"])

s = d.head("AT A GLANCE", "Where this stands today")
cards = [("Data taking", "24-hour rotation", "4 clean", "ok"),
         ("Processing", "follows acquisition live", "lag 3 subruns", "ok"),
         ("Data movement", "local → backup → archive", "checksum verified", "ok"),
         ("Monitoring", "livetime → IBD candidates", "3 stages, automatic", "ok"),
         ("Alarm & mail", "buzzer + expert mail", "delivery confirmed", "ok"),
         ("Auto recovery", "revive a wedged board", "awaiting real fault", "warn")]
bw, gap = (CW - 0.32 * 2) / 3.0, 0.32
for i, (t, sub, chip, kind) in enumerate(cards):
    x = M + (i % 3) * (bw + gap); y = 2.15 + (i // 3) * 1.42
    d.box(s, x, y, bw, 1.22, fill=PANEL); d.box(s, x, y, 0.05, 1.22, fill=ACCENT)
    d.text(s, x + 0.24, y + 0.16, bw - 0.5, 0.3, [[(t, {"size": 17, "bold": True})]])
    d.text(s, x + 0.24, y + 0.53, bw - 0.5, 0.3, [[(sub, {"size": 13.5, "color": INK2})]])
    d.chip(s, x + 0.24, y + 0.83, 2.3, 0.28, chip, kind, size=10.5)
d.note(s, M, 5.20, CW, 1.0, "IN ONE SENTENCE",
       "Something that needed a person watching the screen now runs without one — "
       "and fetches a person when it cannot.", "info")

d.section("01", "ARCHITECTURE", "What controls what, and why it is split this way")

s = d.head("ARCHITECTURE", "We are not the ones touching the hardware")
d.text(s, M, 2.08, CW, 0.4,
       [[("You never have to reason about board behaviour to change this project. "
          "Conversely, if a board misbehaves, look at CUPDAQ, not here.",
          {"size": 16, "color": INK2})]])
d.code(s, M, 2.60, CW, 3.15, [
    "operator / supervisor",
    ("   │", MUTED),
    "   ├─ rcsupervisor ──(child process, restarts on a new run number every N hours)",
    ("   │      │", MUTED),
    "   │      └─ rcterm ──┬─ executedaq.sh ──►  daq / merger / tcb",
    ("   │                 │                    ↑ the hardware lives here (CUPDAQ)", ACC2),
    "   │                 └─ 32-byte socket ──►  commands and queries to those same processes",
    ("   │", MUTED),
    "   ├─ postrun.sh    merge + production, trailing acquisition",
    "   ├─ dataflow.sh   moves finished runs: local → staging → offsite → archive",
    "   ├─ tools/monitor physics figures of merit from finished runs",
    "   └─ daq-notify    turns an event into a buzzer and a mail",
], size=12)
d.note(s, M, 5.95, CW, 0.88, "THE PREMISE",
       "Run control does three things: read the node list, launch a script per node, and "
       "exchange 32-byte messages. Not one line of hardware driver was rewritten.", "info")

s = d.head("ARCHITECTURE", "Why the design is what it is")
d.table(s, M, 2.15, CW, ["What", "How", "Why"],
        [[("Boot order", {"font": MONO, "bold": True}), "by node role, not by name sort",
          "Sorting puts TCB first and clients cannot connect"],
         [("State", {"font": MONO, "bold": True}), "a bitmask, not an integer",
          "Comparing as an integer fails silently. Confirmed from source"],
         [("ADC kind", {"font": MONO, "bold": True}), "substring, not first letter",
          "MERGER is misread as MADC. An undecidable name is a hard error"],
         [("Exit codes", {"font": MONO, "bold": True}), "0 clean / 1 config / 2 run failure",
          "The supervisor separates 'restarting is pointless' from 'worth restarting'"],
         [("Supervisor", {"font": MONO, "bold": True}), "does not link the state machine",
          "A state-machine bug must not take the recovery layer down with it"],
         [("Stop signal", {"font": MONO, "bold": True}), "to one PID, never the group",
          "Signalling the group kills the DAQ mid-write and corrupts the last file"]],
        widths=[2.0, 4.1, CW - 6.1], rh=0.62, size=13.5)
d.foot(s, "The reasoning lives in CLAUDE.md §3 (protocol) and §5 (design decisions) — read it before reverting anything")

s = d.head("DATA FLOW", "The route was decided by the network cards, not by taste")
d.text(s, M, 2.08, CW, 0.4,
       [[("This machine has two interfaces and they differ by a factor of ten. Backup and "
          "archive therefore travel different paths and never starve each other.",
          {"size": 15.5, "color": INK2})]])
d.flow(s, 2.72, [("/Data_ssd", "NVMe 3.7T · take + process", "ok"),
                 ("/data", "RAID 32T · staging", "info"),
                 ("khu server", "offsite backup (1 Gb)", "info"),
                 ("/scratch", "NFS 140T · archive", "warn")],
       h=1.0, labels=["1", "2", "3"])
d.table(s, M, 4.15, CW, ["Stage", "Gate"],
        [["1  /Data_ssd → /data", "processing complete (PRD count = FADC count) · not acquiring · newest keep_ssd runs stay"],
         ["2  /data → khu", "rsync by category, then checksum compare. Only a match marks it done"],
         ["3  /data → /scratch", "only runs that passed stage 2. This is the final resting place"]],
        widths=[3.6, CW - 3.6], rh=0.42, size=13.5)
d.note(s, M, 5.85, CW, 0.95, "BACK UP BEFORE YOU MOVE — IT IS A FACTOR OF SIX",
       "13.9 MB/s while the products are still local, 2.2 MB/s once they are on /scratch. "
       "The take → process → back up → move order is also the fast one.", "warn")

s = d.head("MONITORING", "Confirming the run is healthy in physics terms")
d.flow(s, 2.15, [("1  livetime", "the Event tree in PRD", "info"),
                 ("2  IBD candidates", "waveform → energy → pairing", "info"),
                 ("3  corrected rate", "efficiency + trend plots", "ok")], h=0.95)
d.text(s, M, 3.35, CW, 0.4,
       [[("All three stages read one input: the production output. One macro and one script "
          "per stage, and each skips runs it already did, so re-running is always safe.",
          {"size": 15.5, "color": INK2})]])
d.table(s, M, 4.05, CW, ["", "here", "analysis chain", ""],
        [["single list (run 4237, one subrun)", "5,739", "5,739", ("bit-identical", {"color": OK, "bold": True})],
         ["n-Gd candidates / accidentals", "2,097 / 1,377", "2,097 / 1,377", ("match", {"color": OK, "bold": True})],
         ["n-H candidates / accidentals", "601,739 / 551,422", "601,739 / 551,422", ("match", {"color": OK, "bold": True})]],
        widths=[5.2, 2.5, 2.6, CW - 10.3], rh=0.42, size=13.5)
d.note(s, M, 5.75, CW, 1.0, "THE PHYSICS IS NOT COPIED",
       "Waveform-to-photoelectron conversion and the cut constants are included from the "
       "analysis headers. Copy them and this table alone goes quietly wrong when a cut moves.", "info")

s = d.head("WATCHDOG", "When something breaks, it fetches a person")
d.code(s, M, 2.12, CW, 3.05, [
    "one run fails",
    ("     │", MUTED),
    "     ├─ supervisor restarts on a new number        ──►  notify : restart",
    ("     │", MUTED),
    ("(after five consecutive failures)", ACC2),
    ("     ▼", MUTED),
    "  usb-recover.sh",
    "     ├─ [1] safety   refuses to act while a run is alive",
    "     ├─ [2] triage   refuses to reset without evidence of a USB fault",
    "     ├─ [3] usbreset up to twice, each proven by a real 3-minute run",
    ("     │      ├─ pass → reset the failure counter, carry on taking data", OK),
    ("     │      └─ fail → buzzer + mail to the experts", CRIT),
], size=12.5)
d.bullets(s, M, 5.42, CW, [
    ("The alarm sounds two ways. ", "Sound card and case buzzer, so one dead path is not silence. It repeats until a person silences it."),
    ("The mail carries the diagnosis. ", "Is a run alive, do the three boards enumerate, which log holds USB errors, the last 15 supervisor lines."),
], size=15)

d.section("02", "WHAT CHANGED", "What was wrong, and how it was put right")

s = d.head("CHANGES · ORIGINAL", "Defects the GUI run control carried")
d.table(s, M, 2.12, CW, ["", "What", "Consequence"],
        [["1", "split time passed as an integer", "TypeError on startup"],
         ["2", "boot order sorted on an option string", "with AMOREADC present, TCB is no longer last"],
         ["3", "ADC kind taken from the first letter", "MERGER is classified as MADC"],
         ["4", "calls into functions that do not exist", "the existing text version could not run at all"],
         ["5", "comment contradicts the code", "the minutes/seconds conversion is inverted"],
         ["6", "log directory never created", "the DAQ dies without saying anything"],
         ["7", "example config uses port 22 for a merger", "it grabs the SSH port, and the name lacks an ADC kind"]],
        widths=[0.5, 5.4, CW - 5.9], rh=0.44, size=13.5)
d.note(s, M, 5.65, CW, 0.95, "DO NOT REGRESS THESE",
       "All seven are fixed in the current version. Revert one and the symptom comes straight back.", "warn")

s = d.head("CHANGES · IN SERVICE", "What only unattended running exposed")
d.text(s, M, 2.08, CW, 0.4,
       [[("None of these three are visible while a person is watching. They reproduced on "
          "every rotation once the 24-hour cycle started.", {"size": 15.5, "color": INK2})]])
for i, (t, body, kind) in enumerate([
        ("Defect 1 · every rotation lost the run record",
         "A stop request made the state wait fail immediately. The data files were fine, but the "
         "catalogue row was blank and the exit code said failure. The supervisor ends every run "
         "with a stop signal, so this path reproduced every single time.", "crit"),
        ("Defect 2 · a leftover DAQ captured the previous run's TCB",
         "If the old processes survived, the new ones could not bind the port and died — and run "
         "control happily connected to the old ones and waited forever. A run number was burned too.", "warn"),
        ("Defect 3 · a failed run left no reason behind",
         "Only an unmarked orphan row. It now records, in a sentence, whether the boot failed or the "
         "run started and was never finalised.", "warn")]):
    d.note(s, M, 2.62 + i * 1.32, CW, 1.20, t, body, kind)
d.foot(s, "Five scenarios against a fake detector, plus an A/B against the pre-fix commit that reproduced the field symptom exactly")

s = d.head("CHANGES · DATA", "How files move")
d.table(s, M, 2.12, CW, ["", "Before", "After"],
        [["Moving files", "mv / rsync --remove-source-files", "copy → checksum compare → delete only what passed"],
         ["Backup check", "remote file count only", "rsync -c compares content; a mismatch is not marked done"],
         ["Product location", "written locally, symlinked back", "written where the data is — no place for a link"],
         ["Monitoring input", "read the analysis pairing output", "reads production output only — never waits on anyone"]],
        widths=[2.4, 4.5, CW - 6.9], rh=0.52, size=13.5)
d.note(s, M, 4.70, CW, 1.05, "WHY COUNTING IS NOT ENOUGH",
       "What moves is irreplaceable data, and the archive link is 100 Mb, so transfers are long and "
       "fragile. Counting alone mistakes the debris of an interrupted transfer for success.", "warn")
d.note(s, M, 5.90, CW, 0.9, "AND A JUDGEMENT THAT WAS WRONG",
       "Verifying by checksum costs one eighteenth of the transfer. 'Too expensive' was simply false.", "ok")

s = d.head("CHANGES · SECURITY", "The DAQ control ports faced the internet")
d.bullets(s, M, 2.12, CW, [
    ("Run 4293 died moments after an external connection. ", "It had been perfectly healthy until then."),
    ("A full sweep found 749 connections from 153 distinct addresses over 6.5 months", ", on all three DAQ ports."),
    ("Not once did a valid command value land. ", "The damage comes from queue starvation, not commands — the backlog is three, so a scanner taking a slot pushes run control out."),
], size=15.5)
d.code(s, M, 3.95, CW, 1.35, [
    ("before   public zone: 7809 7813 7814 7815 7816 4280 + NFS", CRIT),
    ("after    six closed — three in use plus three dead rules nobody listened on", OK),
    "",
    "All three nodes are on localhost, so nothing was disrupted. 1,001 Hz throughout, measured.",
])
d.note(s, M, 5.55, CW, 1.0, "STILL OPEN",
       "The NFS ports remain exposed. Find out who is mounting before closing them. The real fix is "
       "binding the DAQ to 127.0.0.1 — that is a CUPDAQ change.", "crit")

s = d.head("CHANGES · OUTAGE", "A wedged FADC board stopped us for 2h09m")
d.code(s, M, 2.12, CW, 1.95, [
    "03:16:08   run 4294 completes its 24 hours cleanly",
    ("03:16:21   rotation → run 4295 ... dead in 12 seconds", CRIT),
    ("           4296 · 4297 · 4298 · 4299 die at exactly the same point", CRIT),
    ("03:20:17   [SUP] FATAL too many consecutive failures; giving up", CRIT),
    "",
    ("           and for over two hours nobody knew", WARN),
])
d.bullets(s, M, 4.28, CW, [
    ("One board, not the system. ", "SADC logged zero errors across all five, TCB measured pedestals normally, and the kernel recorded no disconnect — wedged, not gone."),
    ("Nothing to do with the network. ", "The backup link and the storage mount were both fine at that moment."),
], size=15)
d.note(s, M, 5.70, CW, 1.05, "WHICH IS WHY THIS EXISTS",
       "The steps a person took by hand — triage, usbreset, a short proving run — are now code, with "
       "an alarm and a mail attached. Next time the machine notices first and tries on its own.", "ok")

d.section("03", "MEASUREMENTS", "Only what was actually measured")

s = d.head("MEASUREMENTS", "The bottleneck was never the CPU")
items = [("post-processing · NFS output", 41.0, 41.0, "41.0 s / subrun"),
         ("post-processing · local NVMe", 27.7, 41.0, "27.7 s / subrun   (-32%)"),
         ("monitoring · /scratch", 14.58, 14.58, "14.58 s / subrun"),
         ("monitoring · /Data_ssd", 1.11, 14.58, "1.11 s / subrun   (13x)")]
y = 2.20
for name, v, vmax, lab in items:
    d.text(s, M, y, 3.4, 0.28, [[(name, {"size": 14})]])
    d.bar(s, M + 3.5, y + 0.02, 4.4, 0.24, v / vmax,
          color=ACCENT if v == vmax else OK, label=lab)
    y += 0.52
d.text(s, M, 4.40, CW, 0.35, [[("LINK, MEASURED", {"font": MONO, "size": 12, "bold": True, "color": ACCENT})]])
d.table(s, M, 4.72, CW, ["Path", "Rate", "Used for"],
        [["enp1s0 → storage NFS", ("7.7 MB/s", {"font": MONO, "color": CRIT}), "a 100 Mb interface, at 62% of theory"],
         ["enp0s31f6 → khu", ("15.7 MB/s", {"font": MONO, "color": OK}), "1 Gb. Backup runs here, so the two never compete"]],
        widths=[4.2, 2.2, CW - 6.4], rh=0.42, size=13.5)
d.note(s, M, 6.10, CW, 0.75, "THIS IS NOT ONLY A PROCESSING PROBLEM",
       "Raw data leaves over the same link. There is headroom now, but processing and analysis contend.", "warn")

s = d.head("MEASUREMENTS", "What was checked, and how")
d.table(s, M, 2.12, CW, ["Item", "Result"],
        [["24-hour rotation", ("four clean — ENDED, exit 0, catalogue fully closed", {"color": OK})],
         ["Processing completeness", ("FADC = SADC = Merged = PRD, zero zombies", {"color": OK})],
         ["Full movement chain", ("run 4292 end to end. Stage 3: 348 GB in 10h18m", {"color": OK})],
         ["Monitoring cross-check", ("single list bit-identical, all eight counts match", {"color": OK})],
         ["Alarm and recovery logic", ("ten scenarios against a fake run control, no hardware touched", {"color": OK})],
         ["Mail delivery", ("one owner and six experts, confirmed", {"color": OK})],
         ["Recovery on a real wedged board", ("waits for the next fault", {"color": WARN})]],
        widths=[4.8, CW - 4.8], rh=0.46, size=14)
d.note(s, M, 5.85, CW, 0.95, "WE DO NOT WRITE 'VERIFIED' FOR THINGS WE DID NOT VERIFY",
       "The repository marks verification status explicitly. The last row is what that looks like.", "info")

d.section("04", "WHAT IS NEXT", "What remains, and what is urgent")

s = d.head("WHAT IS NEXT", "In order")
d.table(s, M, 2.12, CW, ["", "Item", "Why"],
        [[("site", {"color": CRIT, "bold": True, "font": MONO, "size": 11.5}),
          "NFS ports face the internet", "Worse in kind than the DAQ ports. Identify the mounts, then close"],
         [("site", {"color": CRIT, "bold": True, "font": MONO, "size": 11.5}),
          "the 100 Mb storage link", "Fixing it turns a 12-hour archive move into one or two. Everything shares this link"],
         [("code", {"color": WARN, "bold": True, "font": MONO, "size": 11.5}),
          "stop earlier on a repeating error", "Hardware faults still burn five run numbers"],
         [("code", {"color": WARN, "bold": True, "font": MONO, "size": 11.5}),
          "reconnect the monitor socket", "A mid-run disconnect is never recovered"],
         [("code", {"color": MUTED, "bold": True, "font": MONO, "size": 11.5}),
          "link libsqlite3 · unit tests", "Parsing and bitmask decoding are pure functions and easy to test"],
         [("phys", {"color": MUTED, "bold": True, "font": MONO, "size": 11.5}),
          "fold in the energy-window efficiency", "It needs a peak fit, so it cannot be derived automatically"]],
        widths=[1.0, 4.9, CW - 5.9], rh=0.60, size=13.5)
d.note(s, M, 6.05, CW, 0.80, "THE TWO URGENT ONES ARE SITE ACTIONS",
       "Nothing else blocks operation today. Fixing the link is the single change that moves the most.", "info")

s = d.head("CLOSING", "In one line")
d.box(s, M, 2.30, CW, 1.55, fill=INK)
d.text(s, M + 0.5, 2.72, CW - 1.0, 0.9,
       [[("Something that needed a person watching now runs without one —\nand fetches a person when it cannot.",
          {"size": 23, "bold": True, "color": PAPER})]], line_spacing=1.25)
d.bullets(s, M, 4.20, CW, [
    ("The repository is the source of truth. ", "This deck is a summary; everything needed to take over lives in the repo."),
    ("Verification status is marked explicitly. ", "Nothing unverified is described as verified."),
    ("The design decisions have reasons. ", "Read CLAUDE.md §5 before reverting any of them."),
], size=15.5)
d.text(s, M, 6.35, CW, 0.4,
       [[("github.com/Sang-Yong/RENE-daq-rcterm", {"font": MONO, "size": 14, "color": ACCENT})]])

OUT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   "..", "..", "docs", "RENE-daq-2026-08-overview-en.pptx"))
d.save(OUT)
print("saved : %s  (%d slides)" % (OUT, len(d.p.slides._sldIdLst)))
