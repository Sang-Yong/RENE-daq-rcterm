tests/usb-recover.test.sh 의 픽스처. 전부 실물을 그대로 복사했다 (2026-11-05).
  FADCDAQ_004424.log  run 4424 부팅 실패 : USB3Read LIBUSB_ERROR_OVERFLOW (+ 정상 'CupFADCT::Open: ... opened' 줄)
  TCB_004425.log      run 4425 : Fail to align DRAM(0..7) 8 줄
  FADCDAQ_004427.log  run 4427 : 'CupFADCT::Open: FADCT [sid=3]: open falied, check connection and power'
  SADCDAQ_004427.log  같은 런의 SADC 로그 (오류 없음)
  TCB_004427.log      DRAM is aligned 8 줄
  TCB_004310.log      2026-08-26 TCB 장애 : USB3TCBWrite/Read LIBUSB_ERROR_TIMEOUT 43 줄 (11.120)
  check-a-*.log       2026-11-03 12:43 확인 런 a : aligned 8 이나 마감 SADC LIBUSB_ERROR_TIMEOUT 1 건 -> 불합격 (11.227)
  check-c-*.log       확인 런 c : DRAM Fail to align 8/8 -> 불합격
  check-d-*.log       확인 런 d : 합격 (aligned 8, USB 오류 0)
  rcterm.log.20261103 /Data/LOG/rcterm.log 의 11-03 10:31~10:33 'booting run 004424~004427' 줄
  dmesg.20261103      dmesg -T 의 'usb 2-4: device descriptor read/8, error -110' 줄 (11-03 10:34)
  check-z-*.log       2026-11-08 09:32 확인 런 #3 (power-2, /Data/LOG/usb-recover-20261108-092004.d/check3-*) : 첫 전원 재투입 뒤
                      DRAM is aligned 8 · USB 오류 0 인데 FADC·SADC 사건 0 (FADC 32628 bytes) = '신호 없음'. 두 번째 전원 재투입
                      (15:42, /Data_ssd/LOG/harness/20261108_usb-recover-forcepower.log) 뒤 확인 런은 6,788 Hz 로 통과했다
  ★ *.log 는 저장소 .gitignore 대상이라 2026-11-08 까지 커밋되지 않았다 (git add -f). 없으면 이 시험은 60 건 넘게 깨진다
