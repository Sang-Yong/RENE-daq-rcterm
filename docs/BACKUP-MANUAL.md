# RENE 데이터 외장하드 백업 — 운용 매뉴얼 (다음 사람용)

저장소 서버(`ssh store`)의 `/data/RAW` 에 쌓인 런을 2 TB USB 외장하드로 옮기고 원본을 지우는 작업이다.
**아래 순서만 따르면 된다.** 왜 그런지는 `CLAUDE.md` §11.140~§11.189 와 스킬 `RENE_daq_data_backup_management_skill` 에 있다.

## 0. 원칙 셋

1. **하드는 종류별로 채운다.** 베이 1 = RAW 하드(원시 파일 FADC·SADC), 베이 2 = PRD 하드(분석 파일 PRD·PNG). Merged 는 담지 않는다(재처리 캐시).
2. **보내고 → 개수·바이트 대조 → 통과한 것만 지운다.** 스크립트가 그렇게 돈다. 대조 전에는 원본이 남아 있으므로 중간에 끊겨도 잃는 것은 없다.
3. **뽑을 때는 두 장을 함께 umount 하고 뽑는다.** 독은 한 USB 장치라 한쪽을 뽑으면 다른 쪽도 떨어진다. 전송 중에 뽑지 않는다.

## 1. 새 하드 두 장 넣기 (root 필요)

```bash
ssh store
lsblk -o NAME,SIZE,MODEL,SERIAL            # 새로 붙은 sdX 두 개 확인 (SERIAL 은 참고용. 진짜 시리얼은 아래 udevadm)
sudo mkfs.ext4 -L RENE /dev/sdb1           # 갓 산 하드라면 파티션을 만든 뒤 포맷 (이미 ext4 면 건너뛴다)
ls -l /dev/disk/by-id/ | grep ata-         # ata-<모델>_<시리얼>-part1 이름 확인
sudo mount /dev/disk/by-id/ata-<모델>_<시리얼A>-part1 /backup_hdd
sudo mount /dev/disk/by-id/ata-<모델>_<시리얼B>-part1 /backup_hdd_2
sudo chown frontend:frontend /backup_hdd /backup_hdd_2     # ★ 안 하면 '쓰기 권한 없음' 으로 멈춘다
```

## 2. 백업 띄우기

```bash
fuser ~/sykim/backup_log/.backup.lock          # 숫자가 나오면 이미 돌고 있다. 두 개를 동시에 띄우지 않는다
/home/frontend/data_backup_simple_code9.sh --disks /backup_hdd   --only raw --dry-run   # 계획만 본다 (안 옮긴다)
/home/frontend/data_backup_simple_code9.sh --disks /backup_hdd_2 --only prd --dry-run
setsid nohup /home/frontend/backup_raw_then_prd.sh > ~/sykim/backup_log/chain.out 2>&1 < /dev/null &
```

`backup_raw_then_prd.sh` 가 **RAW 세션(베이 1) → 끝나면 PRD 세션(베이 2)** 을 차례로 돌린다. 터미널을 닫아도 돈다.
한 세션은 하드가 찰 때까지 약 10 시간(50 MB/s).

## 3. 메일로 알 수 있는 것

메일은 책임자에게 간다 (스크립트 → `/data/MAILQ` → DAQ PC 의 cron 이 5 분마다 발송).

| 메일 | 뜻 | 할 일 |
|---|---|---|
| 세션 시작 … `build=NEW` | 새 세션이 새 판으로 떴다 | 없음 |
| 하드를 다 썼습니다 (code=3) | 그 하드가 찼다 | **다른 세션이 끝난 뒤** 두 장 함께 umount → 교체 → 1·2 반복 |
| 전송 도중 떨어졌습니다 / 유령 마운트 | 독에서 하드가 떨어졌다 | §5 |
| 세션 끝남 | 세션 종료 (정상 code=0/3, 비정상이면 문구가 다르다) | 본문 읽기 |

본문에는 하드의 **시리얼·UUID·용량**, **담긴 것**(런 · part/full · RAW/PRD · 개수 · GB · 서브런 범위), 남은 일, **기록 시트 링크**가 있다.
메일만 보고 어느 하드에 무엇이 있는지 알 수 있어야 한다는 것이 이 본문의 목적이다.

## 4. 하드 빼고 라벨 붙이기

```bash
# (서버)  두 세션이 모두 끝난 뒤
sudo umount /backup_hdd /backup_hdd_2
# (DAQ PC, 저장소 디렉터리)  빼기 전에 한 번 훑어 시트를 갱신하고 라벨을 받는다
scripts/backup-sheet-rebuild.sh --scan --commit
cat docs/BACKUP-DISKS.md            # 라벨 · 시리얼 표. 이 라벨을 스티커로 하드에 붙인다
```

라벨은 `RENE-RAW-NNN` · `RENE-PRD-NNN` (옛 하드는 `RENE-ALL-NNN`, `RENE-MERGED-NNN`). 스티커에 **라벨 + 시리얼**을 쓴다.
시트(`back_up_hdd_log` 탭)의 `Storage Location` 열에 보관 장소를 적는다.

## 5. 문제가 났을 때

| 증상 | 원인 | 조치 |
|---|---|---|
| 기동 화면 `쓰기 권한 없음` | 갓 포맷한 하드는 root 소유 | `sudo chown frontend:frontend /backup_hdd /backup_hdd_2` |
| `이미 백업이 돌고 있습니다 (pid …)` | 세션이 이미 있다 | 끝나기를 기다린다. 죽었으면 `kill -TERM <pid>` (pkill -f 금지) |
| rsync `Input/output error (5)` 가 쏟아짐 · `df` 는 멀쩡 | 하드가 독에서 떨어졌다(유령 마운트) | `dmesg -T \| tail`, `ls /dev/sd*` 로 확인 → `sudo umount -l /backup_hdd` → 다시 꽂고 `sudo e2fsck -f -y /dev/sdX1` → 마운트 → 같은 명령으로 재개 (남은 것부터 이어진다) |
| 메일이 안 온다 | 큐가 막혔다 | DAQ PC 에서 `scripts/mailq-send.sh --status` |
| 시트가 안 늘어난다 | cron 이 죽었다 | DAQ PC 에서 `crontab -l` 에 `backup-sheetlog.sh` 가 있는지, `scripts/backup-sheetlog.sh --status` |
| 시트가 통째로 비었다 | 재작성 중 실패 | `scripts/backup-sheet-rebuild.sh --commit --old-sheet-tsv /Data_ssd/LOG/backup-sheetlog/sheet-before-rebuild-<최근>.tsv` |

## 6. 어디에 무엇이 있나

| 무엇 | 어디 |
|---|---|
| 하드마다 담긴 런 목록 | 시트 `back_up_hdd_log` · 저장소 `docs/backup-disks/<시리얼>_<UUID>.tsv` · 하드 안 `<런>/.part_manifest.txt` |
| 라벨 정본 / 스티커 표 | `docs/backup-disks/disks.tsv` / `docs/BACKUP-DISKS.md` |
| 서버 기록 | `store:~/sykim/backup_log/{backup_log.txt, parts_index.txt, code9.log, code9-prd.log, chain.log}` |
| 스크립트 정본 / 배포본 | `scripts/storage-backup.sh` / `store:/home/frontend/data_backup_simple_code9.sh` (배포는 `.new` + `mv`) |

**스크립트를 고치지 않는 한 위 1~4 만 반복하면 된다.**
