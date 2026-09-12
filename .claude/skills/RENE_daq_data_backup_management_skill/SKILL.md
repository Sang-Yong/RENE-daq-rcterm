---
name: RENE_daq_data_backup_management_skill
description: Use when working on the RENE DAQ data archive to USB disks on the storage server (ssh store) - starting or resuming a backup session, choosing RAW vs PRD disks, labelling disks, rebuilding or checking the back_up_hdd_log Google sheet, reading backup mails, investigating a stalled or dropped disk, or handing the archive over. Covers the code9 script (--only raw|prd), the sheet tools, the label scheme RENE-<RAW|PRD|MERGED|ALL>-NNN and the traps met in 2026-09.
---

# RENE DAQ 데이터 백업 관리 (외장하드 아카이브)

저장소 서버(`ssh store`, 10.0.0.10)의 `/data/RAW`(= DAQ PC 의 `/scratch/RAW`)를 2 TB USB 외장하드로
**옮기고 원본을 지우는** 장기 보관 작업이다. 2026-09-12~13 에 26 장을 전수 스캔해 세운 체계를 그대로 쓴다.
정본은 저장소 `RENE-daq-rcterm` 이고, 자세한 경위는 `CLAUDE.md` §11.140~11.152 · §11.170 · §11.180~11.188.

## 한눈에 — 어디에 무엇이 있나

| 무엇 | 어디 |
|---|---|
| 백업 스크립트 (정본 / 배포본) | `scripts/storage-backup.sh` (한) · `scripts/storage-backup-en.sh` (영) / `store:/home/frontend/data_backup_simple_code9.sh` · `code10.sh` |
| 서버 기록 | `store:~/sykim/backup_log/{backup_log.txt, parts_index.txt (13 열), code9.log, .backup.lock}` |
| 메일 큐 | `store:/data/MAILQ` = DAQ PC `/scratch/MAILQ`, `scripts/mailq-send.sh` (cron 5 분) 이 보낸다. 서버엔 인터넷이 없다 |
| 기록 시트 | GoodRuns 문서의 `back_up_hdd_log` 탭 (gid 219954027). 25 열, (런, 시각) 정렬 |
| 시트 도구 | `scripts/backup-sheetlog.sh` (cron :37, 새 기록 append) · `scripts/backup-sheet-rebuild.sh` (전면 재작성) · `scripts/backup-disk-inventory.sh` (하드 스캔) · `tools/sheetlog/{append_backup_rows,rebuild_backup_sheet}.py` · `tools/sheetlog/disk-inventory-remote.sh` |
| 하드 정본 | `docs/backup-disks/disks.tsv` (라벨 정본) · `docs/BACKUP-DISKS.md` (스티커용 표) · `docs/backup-disks/<시리얼>_<UUID8>.tsv` (하드마다 런별 목록) · `aliases.tsv` · `known-serials.tsv` · `run-notes.tsv` |
| 서비스 계정 열쇠 | 운영 디렉터리 `.config/rene/*.json` 뿐. 작업 클론에서는 `RENE_SHEETS_SA=<그 json>` 으로 넘긴다 |

## 라벨 규칙 (스티커에 쓰는 이름)

`RENE-<종류>-NNN` · 종류 = **RAW**(최상위 FADC·SADC 만) · **PRD**(PRD·PNG 만) · **MERGED**(Merged 만, 재처리 캐시) · **ALL**(섞임, 나누기 전 옛 하드).
번호는 종류별로 처음 담은 날짜 순. **한 번 준 라벨은 `disks.tsv` 에 남아 바뀌지 않는다** — 도구가 지키고, 사람이 고치면 그것이 이긴다.
시리얼은 `udevadm info --query=property --name=/dev/sdX` 의 `ID_SERIAL_SHORT` (lsblk 의 `RANDOM__…` 은 USB 브리지 값, 쓰지 말 것).
스티커에는 라벨 + 시리얼을 함께 적는다.

## 백업 돌리기 (2026-09-13 부터 : RAW 하드와 PRD 하드를 따로)

```bash
# 0) 새 하드 두 장 ext4 로 포맷해 꽂았을 때 (root)
sudo mount /dev/disk/by-id/ata-<모델>_<시리얼>-part1 /backup_hdd        # ls -l /dev/disk/by-id/ | grep ata-
sudo mount /dev/disk/by-id/ata-<모델>_<시리얼>-part1 /backup_hdd_2
sudo chown frontend:frontend /backup_hdd /backup_hdd_2                  # ★ 갓 포맷한 루트는 root 소유. 안 하면 '쓰기 권한 없음'
# 1) 이미 도는 세션이 있는지 (잠금 보유자로. pgrep -f 는 쓰지 않는다)
fuser ~/sykim/backup_log/.backup.lock
# 2) 계획 확인 → 실행.  베이 1 = RAW, 베이 2 = PRD.  ★ 두 세션을 동시에 띄울 수 없다 (잠금 + other_backup). 차례로
/home/frontend/data_backup_simple_code9.sh --disks /backup_hdd   --only raw --dry-run
nohup /home/frontend/data_backup_simple_code9.sh --disks /backup_hdd   --only raw > ~/sykim/backup_log/code9.log 2>&1 &
#    RAW 하드가 차면(code=3 메일) 또는 RAW 가 다 옮겨지면 끝난다. 그 다음 :
nohup /home/frontend/data_backup_simple_code9.sh --disks /backup_hdd_2 --only prd > ~/sykim/backup_log/code9-prd.log 2>&1 &
```

- `--only raw` 는 PRD·PNG 를 남기고(SKIP_DIRS 에 얹음), `--only prd` 는 PRD·PNG 만. Merged 는 어느 쪽도 안 담는다(dataflow M단계가 지운다).
- 한 종류만 담은 런 폴더는 서버에 남는다('부분백업'). 다른 종류 하드가 마저 담아 폴더가 비면 그때 제거된다.
- 옮기는 순서 : 보낸다 → 개수·바이트 대조 → 통과한 것만 지운다. 계획 파일은 회차마다 지운다. 속도 50 MB/s (그 위에서 독이 떨어진 적이 있다).
- 하드가 차면 메일 한 통, 세션이 끝나면 종합 한 통, 오류·이탈이면 그 자리에서 한 통. **모든 메일에 기록 시트 링크와 '담긴 것'(런 · part/full · RAW/PRD · 개수 · GB · 서브런) 요약이 든다.**
- 상태 : `ssh store 'tail -c 400 ~/sykim/backup_log/code9.log | tr "\r" "\n" | tail -3'` · `scripts/mailq-send.sh --status` · `scripts/backup-sheetlog.sh --status`

## 시트 (back_up_hdd_log)

- **매시 37 분 cron 이 새 기록을 뒤에 붙인다** (`backup-sheetlog.sh` → `append_backup_rows.py`). 세션 시작/종료도 알린다(새 판인지 = 세션 시작 시각 ≥ 스크립트 mtime).
- **하드를 꽂을 때마다 통째로 다시 쓴다** : `scripts/backup-sheet-rebuild.sh --scan --commit`
  스캔(시리얼·런별 개수·바이트·서브런·복사 ctime) + 서버 기록 + 옛 시트의 손 열(KHU · 보관 위치 · 메모) → (런, 시각) 정렬 → 라벨 → 쓰기 전 백업 TSV → 되읽어 대조.
  미리보기는 `--commit` 없이. 시트가 비어 있으면 `--old-sheet-tsv /Data_ssd/LOG/backup-sheetlog/sheet-before-rebuild-<최근>.tsv` 로 손 열을 살린다.
- 손 메모는 `docs/backup-disks/run-notes.tsv` 에 `(런, uuid8, 메모)` 로 적으면 재작성 때 Notes 에 ★ 로 붙는다. 재포맷으로 UUID 가 바뀐 하드는 `aliases.tsv`.
- 사람이 채우는 열 : `Storage Location` (그리고 필요하면 `Also at KHU`).

## 하드 꽂고 빼기

- 뽑기 전 `sudo umount /backup_hdd /backup_hdd_2`. 독은 한 USB 장치라 **한쪽을 뽑으면 둘 다 떨어진다.**
- 마운트는 by-id(시리얼)로. `/dev/sdX` 는 붙는 순서일 뿐이다.
- 붙였는데 옛 UUID 가 보이면 실제로 안 바뀐 것이다 : `dmesg -T | grep -E "USB disconnect|Attached SCSI disk|mounted filesystem" | tail`.
- `df` 가 멀쩡해도 `ls /dev/sd*` 에 장치가 없으면 유령 마운트. rsync 가 `Input/output error (5)` 를 쏟으면 장치가 사라진 것(§11.123). 새 판은 전송 중 30 초마다 `disk_alive` 로 잡아 그 자리에서 메일 + exit 1.
- 저널이 끊긴 ext4 는 `e2fsck -f -y /dev/sdX1` 뒤에 마운트.

## 새 배포 (스크립트를 고쳤을 때)

```bash
scp scripts/storage-backup.sh    store:/home/frontend/data_backup_simple_code9.sh.new
scp scripts/storage-backup-en.sh store:/home/frontend/data_backup_simple_code10.sh.new
ssh store 'cd /home/frontend && cp -p data_backup_simple_code9.sh data_backup_simple_code9.sh.bak-$(date +%Y%m%d%H%M) && chmod +x *.new && mv -f data_backup_simple_code9.sh.new data_backup_simple_code9.sh && mv -f data_backup_simple_code10.sh.new data_backup_simple_code10.sh && bash -n data_backup_simple_code9.sh'
```
**★ 반드시 `.new` + `mv` (새 inode).** `scp` 로 제자리 덮어쓰기하면 도는 세션이 루프 밖 코드를 어긋난 자리에서 읽어 죽는다 (09-12 17:07 에 겪었다 — 종료 메일 유실).
한/영 두 판은 같은 패치를 넣고 `tests/parity.test.sh` 로 결과가 같은지 본다.

## 시험 (하드·자료·메일·구글 무접촉)

`tests/storage-backup{,-en}.test.sh` 107 · `parity` 27 · `storage-backup-disklost` 32 · `storage-backup-only` 50+ · `storage-backup-serial` 10 · `storage-backup-sheetlink` 10 ·
`backup-sheetlog` 45 · `backup-rebuild` 66. **스위트는 한 번에 하나씩** — 서버 쪽 `other_backup()` 이 `pgrep -f` 로 이름을 찾으므로 병렬로 돌리면 서로 잡힌다.
**시험 파일을 heredoc 으로 쓰면서 같은 명령줄에서 돌리지 말 것** — 명령줄에 든 `storage-backup.sh` 글자가 '도는 백업' 으로 잡힌다.

## 밟았던 것 (같은 곳을 두 번 밟지 않기 위해)

1. `pgrep -f` 오탐 여섯 가지 — 저장소 경로의 `rcterm` · `$( )` 서브셸 · 조상 argv · 죽은 프로세스 · 감시 명령줄의 대상 이름 · heredoc 명령줄. 세션은 잠금 보유자(`fuser`)로 잡아라.
2. 같은 트리를 두 기계가 만진다 (`/data` = `/scratch`). DAQ PC 의 dataflow 청소가 백업 중인 Merged 를 지워 rc=24 (7 시간 유실). 백업은 Merged 를 안 담는다.
3. 계획 파일 누수 — 앞 하드의 `list.<런>` 이 남으면 보내지도 않은 파일을 지운다. 회차마다 지운다.
4. `du -sb` 로 두 파일시스템을 대조하지 말 것(디렉터리 크기가 다르다). 파일 바이트 합으로.
5. 시트를 `clear()` 뒤 `update()` 하면 실패 시 시트가 빈다 → 먼저 쓰고 남는 줄만 지운다. 쓰기 전 백업 TSV 를 지우지 말 것.
6. 옛 Notes 를 통째로 다시 붙이면 재작성마다 두 배 → 한 칸 50,000 자 초과로 API 거부. 사람이 적은 조각만 한 번.
7. UUID 로만 알던 하드가 스캔되면 물리키가 시리얼로 바뀐다 → 라벨을 물려받게 하고, 표에 없는 키의 라벨도 정본에 남긴다.
8. 런 폴더 없이 `PRD/` `Merged/` 가 바로 놓인 옛 하드(08-26)는 파일 이름에서 런을 읽는다(layout=loose).
9. 시트 메모를 실물보다 믿지 말 것 — "A·B 는 재포맷됐다" 는 메모가 틀렸고 실물이 있었다. 하드는 꽂아서 훑어야 안다.
10. 로그가 없는 옛 하드의 백업 시각은 파일 **ctime** 이다 (rsync -a 는 mtime 만 보존한다).

## 인수인계 때 보는 순서

`docs/BACKUP-DISKS.md` (어느 하드에 무엇) → 시트 → `docs/backup-disks/<시리얼>_*.tsv` (런별) → 서버 `backup_log.txt` · `parts_index.txt` → `CLAUDE.md` §11.170 · §11.187 · §11.188.
