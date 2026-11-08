// ---------------------------------------------------------------------
//  rcsupervisor : rcterm 을 감시하고 런을 자동으로 굴리는 독립 프로그램
//
//  기능
//   1) rcterm 을 자식 프로세스로 실행 (--max-runs 1 로 한 런만 수행)
//   2) --run-length (기본 24h) 이 지나면 rcterm 에 SIGTERM 을 봐서
//      현재 런을 정상적으로 마감(ENDRUN->EXIT, DB 기록)하게 하고,
//      24시간이 다 지나면  새 run 번호로 다시 실행한다.
//   3) --check-period (기본 600s = 10분) 마다 상태를 진단하여
//      보기에 이상하면 DAQ 를 정리한 뒤 새 run 으로 재기동한다.
//
//  진단 항목
//   - heartbeat 파일이 갱신되고 있는가 (rcterm 생존/멈춤 감지)
//   - heartbeat 의 error 바이트가 서 있는가
//   - state 가 Running 인가
//   - TCB 소켓에 직접 물어보아 답이 오는가 / error 가 아닌가
//   - 이벤트 수가 증가하고 있는가 (stall 감지)
//
//  자율 복구 (2026-11-05, 사람 손 없이 돌기 위해)
//   - rcterm exit 1(설정 오류)은 재시작하지 않고 대기(standby)로 간다
//   - 실패한 런의 DAQ 로그에 USB 서명이 있으면 한도를 기다리지 않고 복구
//   - 부팅 뒤 TCB 로그의 DRAM 정렬(is aligned 8 줄)을 확인한다
//   - heartbeat 의 순간 계수율(sr=)이 상한을 넘으면 런을 정상 마감하고 쉰다
//   - 포기(FATAL) 대신 대기-재시도 모드로 남는다. SIGTERM 으로만 끝난다
//   - SIGUSR1 = 지금 런을 정상 마감하고 cooldown 뒤 재기동
//  ★ 판단 근거는 언제나 로그 파일 grep 과 heartbeat 뿐이다 (RunControl 비링크)
// ---------------------------------------------------------------------

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include <libgen.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "OnlConsts.hh"
#include "OnlSocket.hh"

// ================================================================ state
static volatile sig_atomic_t gStop = 0;
static void OnSig(int) { gStop = 1; }
static volatile sig_atomic_t gUsr1 = 0;          // 지금 런 마감 -> cooldown -> 재기동
static void OnUsr1(int) { gUsr1 = 1; }

struct Sup {
   std::string rcterm;                 // rcterm 실행파일 경로
   std::string rctermParams;           // rcterm 에 건네줄 --params 파일
   std::vector<std::string> passthru;  // '--' 뒤로 넘길 rcterm 인자

   double runLengthHour  = 24.0;       // 런 한 개 길이 (로테이션 주기)
   double marginMin      = 30.0;       // rcterm 자체 타이온 여유
   double checkPeriodSec = 600.0;      // 진단 주기 (10분)
   double staleLimitSec  = 300.0;      // heartbeat 갱신 한계
   double graceSec       = 180.0;      // SIGTERM 후 정상종료 대기
   double settleSec      = 10.0;       // 정리 후 대기
   double bootGraceSec   = 300.0;      // 기동 진행중 진단 유예
   double stallGraceSec  = 1800.0;     // stall 판정 유예 (30분)
   double failBackoffSec = 30.0;

   int  maxCycles      = 0;            // 0 = 무한
   int  maxConsecFail  = 5;            // 연속 실패 한계 (초과시 종료)
   bool stallCheck     = true;
   bool socketCheck    = true;
   bool useDB          = true;
   int  startRun       = 0;            // --no-db 에서 사용
   bool dryRun         = false;

   std::string heartbeat = "/Data/LOG/rcterm.hb";
   std::string logFile   = "/Data/LOG/rcsupervisor.log";
   std::string binDir;                 // 정리용 (executedaq.sh 와 같은 디렉토리)

   // ---- 알람 / 메일 / 자동 USB 복구 (2026-08-20 추가) ----
   //  감시자는 이 셋을 '바깥 프로그램'으로만 다룬다. 알림이나 복구 로직이
   //  감시자 안에 들어오면 그것이 죽을 때 감시자까지 끌고 내려간다.
   //  RunControl 을 링크하지 않는 것과 같은 이유다.
   std::string notifyCmd;              // 사건을 알리는 스크립트 (scripts/daq-notify.sh)
   std::string notifyParams;           // 위 스크립트에 넘길 --params
   std::string recoverCmd;             // 자동 USB 복구 (scripts/usb-recover.sh)
   bool        autoRecover = true;     // 연속 실패 한계에서 복구를 시도할까
   std::string daqIP     = RCTERM_DEF_SERVER_IP;
   int         daqPort   = RCTERM_DEF_SERVER_PORT;

   // ---- 자율 복구 (2026-11-05) ----
   bool   standbyEnable   = true;      // 포기하지 않고 대기-재시도로 남는다
   double standbyRetryMin = 60.0;      // 대기 중 재시도 주기 [분]
   bool   earlyRecover    = true;      // USB 서명이 보이면 한도 전에 복구
   bool   dramCheck       = true;      // 부팅 뒤 TCB 로그 DRAM 정렬 확인
   int    dramLines       = 8;         // 'is aligned' 가 이만큼이어야 정상
   double ratePollSec     = 30.0;      // heartbeat sr= 를 읽는 주기 [초]
   double maxRate         = 30000.0;   // ADC 별 순간 계수율 상한 [Hz], 0 = 끔
   int    rateConsec      = 3;         // 연속 이만큼 넘으면 런을 마감한다
   double rateCooldownSec = 600.0;     // 마감 뒤 재기동까지 쉬는 시간 [초]
   int    rateStopLimit   = 3;         // 창 안에서 이만큼 마감하면 standby
   double rateWindowSec   = 7200.0;    // 위의 창 [초]
   int    noEventsLimit   = 2;         // 사건이 한 번도 없던 런(totev 0) 이 연속 이만큼이면 no_events + recover --no-events (전원 재투입까지), 0 = 끔
   std::string daqLogDir    = "/Data_ssd/LOG";             // TCB/FADCDAQ/SADCDAQ_<run>.log
   std::string daqLogDirOld = "/scratch/DAQ_LOG/RAW_log";  // logrotate 가 옮긴 곳
};

static std::ofstream gLog;

// 파일 경로의 상위 디렉터리를 없으면 만든다.
static bool EnsureParentDir(const std::string& path)
{
   if (path.empty()) return true;
   const size_t slash = path.find_last_of('/');
   if (slash == std::string::npos || slash == 0) return true;
   const std::string dir = path.substr(0, slash);
   struct stat st;
   if (::stat(dir.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) return true;

   // mkdir -p 를 손으로 한다. 중간 디렉터리도 만들어야 한다.
   std::string acc;
   size_t p = 0;
   while (p < dir.size()) {
      const size_t next = dir.find('/', p + 1);
      acc = dir.substr(0, next == std::string::npos ? dir.size() : next);
      if (!acc.empty() && ::stat(acc.c_str(), &st) != 0) ::mkdir(acc.c_str(), 0755);
      if (next == std::string::npos) break;
      p = next;
   }
   if (::stat(dir.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
      std::cerr << "[WARN] cannot create directory : " << dir << std::endl;
      return false;
   }
   return true;
}

static std::string TimeStr(time_t t)
{
   char b[64];
   struct tm tmv;
   localtime_r(&t, &tmv);
   strftime(b, sizeof(b), "%Y-%m-%d %H:%M:%S", &tmv);
   return std::string(b);
}

static void Log(const std::string& s)
{
   const std::string line = TimeStr(time(0)) + " [SUP] " + s;
   std::cout << line << std::endl;
   if (gLog.is_open()) gLog << line << std::endl;
}

static std::string Trim(const std::string& s)
{
   size_t a = s.find_first_not_of(" \t\r\n\"");
   if (a == std::string::npos) return "";
   size_t b = s.find_last_not_of(" \t\r\n\"");
   return s.substr(a, b - a + 1);
}

// ====================================================== heartbeat 파싱
static bool ReadHB(const std::string& path, std::map<std::string, std::string>& kv)
{
   kv.clear();
   std::ifstream fp(path.c_str());
   if (!fp.is_open()) return false;
   std::string line;
   while (std::getline(fp, line)) {
      size_t eq = line.find('=');
      if (eq == std::string::npos) continue;
      kv[Trim(line.substr(0, eq))] = Trim(line.substr(eq + 1));
   }
   return !kv.empty();
}

static std::string HBGet(const std::map<std::string, std::string>& kv,
                         const char* k, const char* def = "")
{
   std::map<std::string, std::string>::const_iterator it = kv.find(k);
   return (it == kv.end()) ? std::string(def) : it->second;
}

// ========================================================= child 제어
static std::vector<std::string> BuildArgs(const Sup& c, int runForNoDB)
{
   std::vector<std::string> av;
   av.push_back(c.rcterm);
   if (!c.rctermParams.empty()) {
      av.push_back("--params");
      av.push_back(c.rctermParams);
   }
   // --- 감시자가 강제하는 설정 (params 보다 뒤에 오므로 이긴다) ---
   av.push_back("--max-runs");  av.push_back("1");
   char b[64];
   // rcterm 자체 타이머는 감시자보다 늦게 도달하도록 여유를 둔다.
   snprintf(b, sizeof(b), "%.6f", c.runLengthHour + c.marginMin / 60.0);
   av.push_back("--run-length"); av.push_back(b);
   av.push_back("--quiet");
   av.push_back("--heartbeat"); av.push_back(c.heartbeat);
   if (!c.useDB) {
      av.push_back("--no-db");
      av.push_back("--run");
      av.push_back(std::to_string(runForNoDB));
   }
   for (size_t i = 0; i < c.passthru.size(); ++i) av.push_back(c.passthru[i]);
   return av;
}

static pid_t SpawnRcterm(const Sup& c, int cycle, int runForNoDB)
{
   const std::vector<std::string> av = BuildArgs(c, runForNoDB);
   std::ostringstream shown;
   for (size_t i = 0; i < av.size(); ++i) shown << (i ? " " : "") << av[i];
   Log("cycle " + std::to_string(cycle) + " launch: " + shown.str());

   if (c.dryRun) return 0;

   pid_t pid = ::fork();
   if (pid < 0) {
      Log("ERROR fork() failed");
      return -1;
   }
   if (pid == 0) {
      ::setpgid(0, 0);                       // 자식을 새 프로세스 그룹으로
      std::vector<char*> cav;
      for (size_t i = 0; i < av.size(); ++i)
         cav.push_back(const_cast<char*>(av[i].c_str()));
      cav.push_back(0);
      ::execvp(av[0].c_str(), &cav[0]);
      std::fprintf(stderr, "execvp failed: %s\n", av[0].c_str());
      ::_exit(127);
   }
   ::setpgid(pid, pid);                      // race 방지로 부모도 한 번 더
   return pid;
}

// 정상 종료 시도 -> 실패하면 그룹 전송
//  주의: SIGTERM 은 rcterm 단일 PID 에만 보낸다.
//        그룹에 보내면 daq/tcb/merger 가 쓰기 도중에 죽어 파일이 상한다.
static int StopRcterm(pid_t pid, double graceSec, bool& graceful)
{
   graceful = false;
   int status = 0;
   if (pid <= 0) return -1;

   ::kill(pid, SIGTERM);
   double w = 0;
   while (w < graceSec) {
      if (::waitpid(pid, &status, WNOHANG) == pid) { graceful = true; return status; }
      ::usleep(200000);
      w += 0.2;
   }
   Log("WARN rcterm did not exit within grace; sending SIGKILL to process group");
   ::kill(-pid, SIGKILL);
   ::waitpid(pid, &status, 0);
   return status;
}

// 남은 DAQ 프로세스 정리. executedaq.sh 는 tcb/daq/merger 를
// <bindir>/<exe> 토큰으로 백그라운드 실행하므로 경로 패턴으로 집어낸다.
static void CleanupStale(const Sup& c)
{
   if (c.binDir.empty()) {
      Log("WARN --bindir not set; skipping stale DAQ process cleanup");
      return;
   }
   const char* bins[] = {"tcb", "merger", "daq", 0};
   for (int i = 0; bins[i]; ++i) {
      char cmd[768];
      snprintf(cmd, sizeof(cmd), "pkill -f '%s/%s' >/dev/null 2>&1",
               c.binDir.c_str(), bins[i]);
      Log(std::string("cleanup: ") + cmd);
      if (!c.dryRun) ::system(cmd);
   }
   ::usleep(1000000);
   for (int i = 0; bins[i]; ++i) {
      char cmd[768];
      snprintf(cmd, sizeof(cmd), "pkill -9 -f '%s/%s' >/dev/null 2>&1",
               c.binDir.c_str(), bins[i]);
      if (!c.dryRun) ::system(cmd);
   }
}

// ====================================================== 알림 / 자동 복구
//  셸 인자로 나가는 값에서 작은따옴표를 없앤다. 사유 문자열은 로그에서
//  온 것이라 따옴표가 섞일 수 있고, 그대로 넘기면 명령이 깨진다.
static std::string ShQuote(const std::string& in)
{
   std::string o = "'";
   for (size_t i = 0; i < in.size(); ++i) {
      if (in[i] == '\'') o += "'\\''";
      else if (in[i] == '\n' || in[i] == '\r') o += ' ';
      else o += in[i];
   }
   o += "'";
   return o;
}

//  사건 하나를 바깥 스크립트에 넘긴다.
//  ★ 실패해도 감시자는 계속 간다. 알림이 안 나가는 것보다 수집이 멎는 것이 나쁘다.
static void Notify(const Sup& c, const char* event,
                   const std::string& run, const std::string& msg)
{
   if (c.notifyCmd.empty()) return;
   std::string cmd = c.notifyCmd;
   if (!c.notifyParams.empty()) cmd += " --params " + ShQuote(c.notifyParams);
   cmd += " ";
   cmd += event;
   if (!run.empty()) cmd += " --run " + ShQuote(run);
   if (!msg.empty()) cmd += " --msg " + ShQuote(msg);
   cmd += " >/dev/null 2>&1 &";          // 알림 때문에 감시가 멈추면 안 된다
   Log(std::string("notify: ") + event + (msg.empty() ? "" : " : " + msg));
   if (!c.dryRun) { int rc = ::system(cmd.c_str()); (void)rc; }
}

//  자동 USB 복구를 부르고 그 판정을 그대로 돌려준다.
//   0 복구됨 / 1 USB 문제 아님 / 2 복구 실패 / 3 안전조건 미달 / 그 외 실행 실패
//  ★ 이쪽은 백그라운드로 돌리지 않는다. 결과를 보고 다음 행동을 정해야 한다.
//  extra : 복구 스크립트에 덧붙일 인자 (사건 0 런 연속이면 " --no-events" -- 전원 재투입까지 허용)
static int RunRecover(const Sup& c, const std::string& extra = "")
{
   if (c.recoverCmd.empty()) return -1;
   std::string cmd = c.recoverCmd + extra;
   if (!c.notifyParams.empty()) cmd += " --params " + ShQuote(c.notifyParams);
   Log("recover: " + cmd);
   if (c.dryRun) return -1;
   int rc = ::system(cmd.c_str());
   if (rc == -1) return -1;
   return WIFEXITED(rc) ? WEXITSTATUS(rc) : -1;
}


//  설정 오류(exit 1) 대기 중 : 같은 인자로 rcterm --dry-run 이 통과하는가.
//  rcterm 의 dry-run 은 DB 도 하드웨어도 건드리지 않는다 (RunControl.cc 의 dryRun 가드).
static bool ConfigDryRunOK(const Sup& c, int runForNoDB, int& rcOut)
{
   std::vector<std::string> av = BuildArgs(c, runForNoDB);
   av.push_back("--dry-run");
   std::string cmd;
   for (size_t i = 0; i < av.size(); ++i) cmd += (i ? " " : "") + ShQuote(av[i]);
   cmd += " >/dev/null 2>&1";
   Log("config check : " + cmd);
   if (c.dryRun) { rcOut = -1; return false; }
   const int rc = ::system(cmd.c_str());
   rcOut = (rc != -1 && WIFEXITED(rc)) ? WEXITSTATUS(rc) : -1;
   return rcOut == 0;
}

// ================================================= 자율 복구 도우미 (2026-11-05)
//  신호가 오면 바로 깨는 잠. gStop 이 서면 일찍 돌아온다.
static void SleepFor(double sec)
{
   double w = 0;
   while (w < sec && !gStop) { ::usleep(200000); w += 0.2; }
}

static std::string Pad6(const std::string& run)
{
   char b[32];
   snprintf(b, sizeof(b), "%06d", atoi(run.c_str()));
   return b;
}

//  <kind>_<run6>.log 를 운영 자리 -> logrotate 가 옮긴 자리 순으로 찾는다.
static std::string FindDaqLog(const Sup& c, const char* kind, const std::string& run)
{
   if (run.empty() || atoi(run.c_str()) <= 0) return "";
   const std::string name = std::string(kind) + "_" + Pad6(run) + ".log";
   const std::string dirs[2] = {c.daqLogDir, c.daqLogDirOld};
   for (int i = 0; i < 2; ++i) {
      if (dirs[i].empty()) continue;
      const std::string path = dirs[i] + "/" + name;
      if (::access(path.c_str(), R_OK) == 0) return path;
   }
   return "";
}

static bool Has(const std::string& l, const char* k) { return l.find(k) != std::string::npos; }
static bool IsAligned(const std::string& l)   { return Has(l, "is aligned"); }
static bool IsAlignFail(const std::string& l) { return Has(l, "Fail to align"); }
static bool IsUsbSig(const std::string& l)
{
   return Has(l, "LIBUSB_ERROR_") || Has(l, "open falied") || Has(l, "Fail to align")
       || (Has(l, "USB3TCB") && Has(l, "error"));
}
static bool IsCloseErr(const std::string& l) { return Has(l, "TIMEOUT") || Has(l, "OVERFLOW"); }

static int CountLines(const std::string& path, bool (*pred)(const std::string&))
{
   if (path.empty()) return 0;
   std::ifstream fp(path.c_str());
   if (!fp.is_open()) return 0;
   int n = 0;
   std::string line;
   while (std::getline(fp, line)) if (pred(line)) ++n;
   return n;
}

//  세 DAQ 로그에서 pred 에 맞는 줄을 센다. where 에 '파일 : 건수' 를 모은다.
static int ScanRunLogs(const Sup& c, const std::string& run,
                       bool (*pred)(const std::string&), std::string& where)
{
   const char* kinds[] = {"TCB", "FADCDAQ", "SADCDAQ", 0};
   int tot = 0;
   where.clear();
   for (int i = 0; kinds[i]; ++i) {
      const std::string f = FindDaqLog(c, kinds[i], run);
      const int n = CountLines(f, pred);
      if (n > 0) {
         tot += n;
         if (!where.empty()) where += ", ";
         where += std::string(kinds[i]) + " " + std::to_string(n);
      }
   }
   return tot;
}

//  heartbeat 의 daqN= 줄에서 sr= 의 최댓값. 합·평균이 아니라 최댓값 (한 보드만 폭주해도 잡는다).
static double MaxSR(const std::map<std::string, std::string>& hb)
{
   double mx = -1;
   for (std::map<std::string, std::string>::const_iterator it = hb.begin(); it != hb.end(); ++it) {
      if (it->first.compare(0, 3, "daq") != 0 || it->first == "daqtime") continue;
      const size_t p = it->second.find(" sr=");
      if (p == std::string::npos) continue;
      const double v = atof(it->second.c_str() + p + 4);
      if (v > mx) mx = v;
   }
   return mx;
}

//  대기 상태는 rcterm.hb 가 아니라 별도 파일 <heartbeat>.sup 에 쓴다.
//  ★ rcterm.hb 의 time= 를 갱신하면 dataflow · postrun · badrun · websummary 가
//    마지막 런을 '수집 중' 으로 보고 꼬리 처리·이동을 무기한 막는다 (리뷰 2026-11-05).
//    그래서 rcterm.hb 는 한 바이트도 건드리지 않는다.
static std::string SupStatePath(const Sup& c) { return c.heartbeat + ".sup"; }

static void WriteSupState(const Sup& c, const std::string& kind,
                          const std::string& run, time_t since)
{
   if (c.heartbeat.empty() || c.dryRun) return;
   const std::string path = SupStatePath(c);
   const std::string tmp  = path + ".tmp";
   {
      std::ofstream o(tmp.c_str());
      if (!o.is_open()) return;
      o << "time="    << (long long)time(0)     << "\n"
        << "pid="     << (long long)::getpid()  << "\n"
        << "phase=standby\n"
        << "standby=" << kind                   << "\n"
        << "run="     << run                    << "\n"
        << "since="   << (long long)since       << "\n";
   }
   ::rename(tmp.c_str(), path.c_str());
}

static void ClearSupState(const Sup& c)
{
   if (c.heartbeat.empty() || c.dryRun) return;
   ::unlink(SupStatePath(c).c_str());
}

// ============================================================== 진단
struct HealthState {
   unsigned long long lastTot = 0;
   bool   haveTot   = false;
   time_t lastAdvance = 0;
   bool   sawEvents = false;   // 이 런에서 totev 가 한 번이라도 0 을 넘었나 (2026-11-08 run 4441~4445)
};

// true = 정상, false = 이상(reason 에 이상 사유)
static bool CheckHealth(const Sup& c, time_t launchTime,
                        HealthState& hs, std::string& reason)
{
   const time_t now = time(0);
   const double sinceLaunch = (double)(now - launchTime);

   // ---- 1) heartbeat --------------------------------------------------
   std::map<std::string, std::string> hb;
   if (!ReadHB(c.heartbeat, hb)) {
      if (sinceLaunch < c.bootGraceSec) { reason = ""; return true; }   // 기동중
      reason = "heartbeat file not readable: " + c.heartbeat;
      return false;
   }

   const long long hbTime = atoll(HBGet(hb, "time", "0").c_str());
   const double    age    = (double)(now - (time_t)hbTime);
   if (age > c.staleLimitSec) {
      char b[160];
      snprintf(b, sizeof(b), "heartbeat stale : %.0f s old (limit %.0f s)",
               age, c.staleLimitSec);
      reason = b;
      return false;
   }

   const std::string phase = HBGet(hb, "phase", "?");
   const std::string state = HBGet(hb, "state", "?");

   // ---- 2) error 바이트 ------------------------------------------------
   if (atoi(HBGet(hb, "error", "0").c_str()) != 0) {
      reason = "DAQ error bit set (state=" + state + ")";
      return false;
   }

   // 기동/종료 구간은 이하 점검을 생략한다
   if (phase != "running") {
      if (phase == "error" || phase == "failed") {
         reason = "rcterm reported phase=" + phase;
         return false;
      }
      if (sinceLaunch > c.bootGraceSec && phase != "ending" && phase != "ended") {
         reason = "still phase=" + phase + " after boot grace";
         return false;
      }
      reason = "";
      return true;
   }

   // ---- 3) state 가 Running 인가 ---------------------------------------
   if (state != "Running") {
      reason = "phase=running but DAQ state=" + state;
      return false;
   }

   // ---- 4) TCB 소켓 진짜 질의 --------------------------------------
   if (c.socketCheck) {
      OnlSocket s(c.daqIP, c.daqPort);
      if (!s.Connect(5)) {
         reason = "cannot connect to TCB " + c.daqIP + ":" + std::to_string(c.daqPort);
         return false;
      }
      OnlMessage m;
      if (!s.Query(onl::kQUERYDAQSTATUS, m)) {
         reason = "TCB did not answer QUERYDAQSTATUS";
         return false;
      }
      if (CheckError(m.m1)) {
         char b[96];
         snprintf(b, sizeof(b), "TCB status has ERROR bit (0x%llx)",
                  (unsigned long long)m.m1);
         reason = b;
         return false;
      }
      if (!CheckState(m.m1, onl::kRUNNING)) {
         char b[96];
         snprintf(b, sizeof(b), "TCB is not RUNNING (status=0x%llx)",
                  (unsigned long long)m.m1);
         reason = b;
         return false;
      }
   }

   // ---- 5) 이벤트 수 증가 (stall) ----------------------------------
   if (c.stallCheck) {
      const unsigned long long tot =
         strtoull(HBGet(hb, "totev", "0").c_str(), 0, 10);
      if (tot > 0) hs.sawEvents = true;
      if (!hs.haveTot) {
         hs.haveTot     = true;
         hs.lastTot     = tot;
         hs.lastAdvance = now;
      } else if (tot > hs.lastTot) {
         hs.lastTot     = tot;
         hs.lastAdvance = now;
      } else if (sinceLaunch > c.stallGraceSec &&
                 (double)(now - hs.lastAdvance) > c.stallGraceSec) {
         char b[192];
         snprintf(b, sizeof(b),
                  "no new events for %.0f s (totev stuck at %llu)",
                  (double)(now - hs.lastAdvance), (unsigned long long)tot);
         reason = b;
         return false;
      }
   }

   reason = "";
   return true;
}

// ================================================= 대기-재시도 모드 (S-5)
//  포기하지 않는다. 주기마다 다시 해 보고, 되면 수집을 잇는다. SIGTERM 으로만 끝난다.
enum { SB_NONE = 0, SB_CONFIG = 1, SB_HARDWARE = 2, SB_RATE = 3 };
static const char* SBName(int k)
{
   return k == SB_CONFIG ? "config" : k == SB_HARDWARE ? "hardware" : k == SB_RATE ? "rate" : "none";
}

//  0 = SIGTERM 으로 끝남
//  1 = 재개 (확인 런, recover 를 부르지 않았다)
//  2 = 재개 (recover 0 : 복구 스크립트가 recovered 를 이미 알렸다)
//  3 = 재개 (recover 1 : 확인 런. recover 를 막 불렀으므로 그 런이 실패해도 또 부르지 않는다)
//  what 에는 무엇으로 재개했는지가 담긴다 (확인 런이 통과한 뒤의 recovered 본문)
static int Standby(const Sup& c, int kind, const std::string& run, int runProbe,
                   std::string& whatOut, const std::string& recoverExtra = "")
{
   const double retrySec = c.standbyRetryMin * 60.0;
   const time_t since = time(0);
   char b[256];
   snprintf(b, sizeof(b), "STANDBY (%s) : retry every %.1f min; SIGTERM to stop",
            SBName(kind), c.standbyRetryMin);
   Log(b);
   WriteSupState(c, SBName(kind), run, since);
   time_t next = time(0) + (time_t)retrySec;
   int nTry = 0;
   while (!gStop) {
      const double left = (double)(next - time(0));
      SleepFor(left < 60 ? (left > 0 ? left : 0.2) : 60);
      if (gStop) break;
      WriteSupState(c, SBName(kind), run, since);
      if (gUsr1) { gUsr1 = 0; Log("SIGUSR1 ignored while in standby"); }
      if (time(0) < next) continue;
      next = time(0) + (time_t)retrySec;
      ++nTry;

      int how = 0;
      std::string what;
      if (kind == SB_CONFIG) {
         int rc = -1;
         if (ConfigDryRunOK(c, runProbe, rc)) how = 1;
         what = "rcterm --dry-run returned " + std::to_string(rc);
      } else if (kind == SB_HARDWARE && c.autoRecover && !c.recoverCmd.empty()) {
         const int rrc = RunRecover(c, recoverExtra);
         what = "recover returned " + std::to_string(rrc);
         if (rrc == 0) how = 2;
         else if (rrc == 1) { how = 3; what += " (not usb : one probe run)"; }
      } else {
         how = 1;
         what = "probe run";
      }
      snprintf(b, sizeof(b), "standby retry #%d (%s) : %s -> %s",
               nTry, SBName(kind), what.c_str(), how ? "resume" : "stay");
      Log(b);
      Notify(c, "standby_retry", run, b);
      if (how) {
         whatOut = what;
         Log(std::string("leaving standby (") + SBName(kind) + ")");
         ClearSupState(c);
         return how;
      }
      WriteSupState(c, SBName(kind), run, since);
   }
   ClearSupState(c);
   return 0;
}

// =============================================================== usage
static void Usage(const char* p)
{
   std::cout <<
"\nUsage: " << p << " [OPTIONS] [-- <extra args passed to rcterm>]\n"
"       " << p << " --params <file>\n"
"\n"
" What it does\n"
"   Runs rcterm as a child (one run per launch), rotates the run every\n"
"   --run-length hours, and restarts the DAQ automatically when the\n"
"   periodic health check says something is wrong.\n"
"\n"
" Child program\n"
"   --rcterm PATH          path to rcterm  (default: next to this binary)\n"
"   --rcterm-params FILE   params file handed to rcterm      [recommended]\n"
"\n"
" Rotation\n"
"   --run-length HOUR      one run length / rotation period          (24)\n"
"   --margin MIN           extra margin given to rcterm timer        (30)\n"
"   --max-cycles N         stop after N runs, 0 = unlimited           (0)\n"
"\n"
" Health check\n"
"   --check-period SEC     diagnosis period                        (600)\n"
"   --stale-limit SEC      max heartbeat age                       (300)\n"
"   --boot-grace SEC       skip checks while booting                (300)\n"
"   --stall-grace SEC      allow this long without new events     (1800)\n"
"   --no-stall-check       do not treat a frozen event counter as bad\n"
"   --no-socket-check      do not query the TCB socket directly\n"
"   --grace SEC            wait after SIGTERM before SIGKILL        (180)\n"
"   --settle SEC           wait after cleanup                       (10)\n"
"   --backoff SEC          wait after a failed cycle                (30)\n"
"   --max-consec-fail N    give up after N consecutive failures       (5)\n"
"\n"
" Paths / site\n"
"   --heartbeat FILE       (/Data/LOG/rcterm.hb)\n"
"   --log FILE             (/Data/LOG/rcsupervisor.log)\n"
"   --bindir DIR           dir of tcb/daq/merger, for stale cleanup\n"
"   --daqserver IP         (" RCTERM_DEF_SERVER_IP ")\n"
"   --daqport PORT         (7809)\n"
"   --no-db                rcterm runs without the run catalog DB\n"
"   --run N                first run number when --no-db\n"
"   --dry-run              show what would happen, spawn nothing\n"
"\n"
" Alarm / mail / automatic USB recovery\n"
"   --notify-cmd PATH      script called on each event (scripts/daq-notify.sh)\n"
"   --notify-params FILE   passed to it as --params  (config/notify.params)\n"
"   --recover-cmd PATH     automatic USB recovery    (scripts/usb-recover.sh)\n"
"   --no-notify            do not call the notify script at all\n"
"   --no-auto-recover      never run usbreset automatically\n"
"\n"
" Autonomy (no human needed)\n"
"   --no-standby           old behaviour: give up (exit 1/2) instead of standby\n"
"   --standby-retry-min M  retry period while in standby [min]          (60)\n"
"   --no-early-recover     wait for --max-consec-fail even with USB errors\n"
"   --dram-check 0|1       check 'is aligned' lines in TCB log after boot (1)\n"
"   --dram-lines N         expected 'is aligned' lines                    (8)\n"
"   --rate-poll SEC        heartbeat sr= poll period                     (30)\n"
"   --max-rate HZ          per-ADC instantaneous rate limit, 0 = off  (30000)\n"
"   --rate-consec N        consecutive polls over the limit to act        (3)\n"
"   --rate-cooldown SEC    rest after a rate stop before relaunch       (600)\n"
"   --rate-stop-limit N    rate stops within the window -> standby        (3)\n"
"   --rate-window SEC      the window                                  (7200)\n"
"   --no-events-limit N    runs in a row that never saw an event (totev 0)\n"
"                          -> no_events + recover --no-events, 0 = off   (2)\n"
"   --daq-logdir DIR       DAQ logs  TCB_<run6>.log ...       (/Data_ssd/LOG)\n"
"   --daq-logdir-old DIR   rotated DAQ logs        (/scratch/DAQ_LOG/RAW_log)\n"
"\n"
" Signals\n"
"   SIGTERM / SIGINT       end the current run gracefully and exit 0\n"
"   SIGUSR1                end the current run gracefully, cooldown, relaunch\n"
"\n"
" Exit codes\n"
"   0 normal stop   1 bad options (or rcterm config error with --no-standby)\n"
"   2 gave up (only with --no-standby)\n"
"   -h, --help\n"
<< std::endl;
}

static bool LoadParams(const std::string& file, std::vector<std::string>& args)
{
   std::ifstream fp(file.c_str());
   if (!fp.is_open()) {
      std::cerr << "[FATAL] cannot read params file : " << file << std::endl;
      return false;
   }
   std::string line;
   while (std::getline(fp, line)) {
      size_t h = line.find('#');
      if (h != std::string::npos) line = line.substr(0, h);
      line = Trim(line);
      if (line.empty()) continue;
      size_t eq = line.find('=');
      std::string k = Trim(eq == std::string::npos ? line : line.substr(0, eq));
      std::string v = (eq == std::string::npos) ? "" : Trim(line.substr(eq + 1));
      if (k.empty()) continue;
      args.push_back("--" + k);
      if (!v.empty()) args.push_back(v);
   }
   return true;
}

// ================================================================ main
int main(int argc, char** argv)
{
   Sup c;

   // rcterm 기본 경로 : 이 바이너리와 같은 디렉토리
   {
      char buf[4096];
      std::strncpy(buf, argv[0], sizeof(buf) - 1);
      buf[sizeof(buf) - 1] = 0;
      std::string dir = ::dirname(buf);
      c.rcterm = (dir == ".") ? std::string("rcterm") : dir + "/rcterm";
   }

   std::vector<std::string> a;
   bool afterDD = false;
   for (int i = 1; i < argc; ++i) {
      const std::string s = argv[i];
      if (afterDD)         { c.passthru.push_back(s); continue; }
      if (s == "--")       { afterDD = true; continue; }
      if (s == "--params") {
         if (i + 1 >= argc) { std::cerr << "--params needs FILE" << std::endl; return 1; }
         if (!LoadParams(argv[++i], a)) return 1;
         continue;
      }
      a.push_back(s);
   }
   if (a.empty() && c.passthru.empty()) { Usage(argv[0]); return 1; }

   for (size_t i = 0; i < a.size(); ++i) {
      const std::string o = a[i];
      const std::string v = (i + 1 < a.size()) ? a[i + 1] : "";
      #define VAL if (v.empty() || v.substr(0, 2) == "--") {                    \
                     std::cerr << o << " needs a value" << std::endl; return 1; \
                  } ++i;

      if      (o == "-h" || o == "--help")   { Usage(argv[0]); return 0; }
      else if (o == "--rcterm")              { VAL c.rcterm = v; }
      else if (o == "--rcterm-params")       { VAL c.rctermParams = v; }
      else if (o == "--run-length")          { VAL c.runLengthHour = atof(v.c_str()); }
      else if (o == "--margin")              { VAL c.marginMin = atof(v.c_str()); }
      else if (o == "--max-cycles")          { VAL c.maxCycles = atoi(v.c_str()); }
      else if (o == "--check-period")        { VAL c.checkPeriodSec = atof(v.c_str()); }
      else if (o == "--stale-limit")         { VAL c.staleLimitSec = atof(v.c_str()); }
      else if (o == "--boot-grace")          { VAL c.bootGraceSec = atof(v.c_str()); }
      else if (o == "--stall-grace")         { VAL c.stallGraceSec = atof(v.c_str()); }
      else if (o == "--no-stall-check")      { c.stallCheck = false; }
      else if (o == "--no-socket-check")     { c.socketCheck = false; }
      else if (o == "--grace")               { VAL c.graceSec = atof(v.c_str()); }
      else if (o == "--settle")              { VAL c.settleSec = atof(v.c_str()); }
      else if (o == "--backoff")             { VAL c.failBackoffSec = atof(v.c_str()); }
      else if (o == "--max-consec-fail")     { VAL c.maxConsecFail = atoi(v.c_str()); }
      else if (o == "--heartbeat")           { VAL c.heartbeat = v; }
      else if (o == "--log")                 { VAL c.logFile = v; }
      else if (o == "--bindir")              { VAL c.binDir = v; }
      else if (o == "--daqserver")           { VAL c.daqIP = v; }
      else if (o == "--daqport")             { VAL c.daqPort = atoi(v.c_str()); }
      else if (o == "--no-db")               { c.useDB = false; }
      else if (o == "--run")                 { VAL c.startRun = atoi(v.c_str()); }
      else if (o == "--dry-run")             { c.dryRun = true; }
      else if (o == "--notify-cmd")          { VAL c.notifyCmd = v; }
      else if (o == "--notify-params")       { VAL c.notifyParams = v; }
      else if (o == "--recover-cmd")         { VAL c.recoverCmd = v; }
      else if (o == "--no-notify")           { c.notifyCmd.clear(); }
      else if (o == "--no-auto-recover")     { c.autoRecover = false; }
      else if (o == "--no-standby")          { c.standbyEnable = false; }
      else if (o == "--standby-retry-min")   { VAL c.standbyRetryMin = atof(v.c_str()); }
      else if (o == "--no-early-recover")    { c.earlyRecover = false; }
      else if (o == "--dram-check")          { VAL c.dramCheck = atoi(v.c_str()) != 0; }
      else if (o == "--dram-lines")          { VAL c.dramLines = atoi(v.c_str()); }
      else if (o == "--rate-poll")           { VAL c.ratePollSec = atof(v.c_str()); }
      else if (o == "--max-rate")            { VAL c.maxRate = atof(v.c_str()); }
      else if (o == "--no-events-limit")     { VAL c.noEventsLimit = atoi(v.c_str()); }
      else if (o == "--rate-consec")         { VAL c.rateConsec = atoi(v.c_str()); }
      else if (o == "--rate-cooldown")       { VAL c.rateCooldownSec = atof(v.c_str()); }
      else if (o == "--rate-stop-limit")     { VAL c.rateStopLimit = atoi(v.c_str()); }
      else if (o == "--rate-window")         { VAL c.rateWindowSec = atof(v.c_str()); }
      else if (o == "--daq-logdir")          { VAL c.daqLogDir = v; }
      else if (o == "--daq-logdir-old")      { VAL c.daqLogDirOld = v; }
      else {
         std::cerr << "unknown option : " << o << std::endl;
         Usage(argv[0]);
         return 1;
      }
      #undef VAL
   }

   if (c.runLengthHour <= 0)  { std::cerr << "--run-length must be > 0" << std::endl; return 1; }
   if (c.checkPeriodSec <= 0) { std::cerr << "--check-period must be > 0" << std::endl; return 1; }
   if (c.ratePollSec <= 0)    { std::cerr << "--rate-poll must be > 0" << std::endl; return 1; }
   if (c.standbyRetryMin <= 0){ std::cerr << "--standby-retry-min must be > 0" << std::endl; return 1; }
   if (c.rateConsec < 1)      c.rateConsec = 1;
   if (c.rateStopLimit < 1)   c.rateStopLimit = 1;
   if (c.noEventsLimit < 0)   c.noEventsLimit = 0;
   if (!c.useDB && c.startRun <= 0) {
      std::cerr << "--no-db requires --run <first run number>" << std::endl;
      return 1;
   }
   if (c.binDir.empty()) {
      const char* od = ::getenv("ONLDAQ_DIR");
      if (od && *od) c.binDir = std::string(od) + "/bin";
   }

   // 로그와 heartbeat 가 놓일 디렉터리를 미리 만든다.
   //  실측 사고(2026-08-17): /Data/LOG 가 지워진 채로 돌자 rcterm 이 heartbeat 를
   //  못 써서 감시자가 멀쩡한 런을 죽이고 재시작했다. 감시자가 heartbeat 를
   //  '읽는' 쪽이지만, 디렉터리는 여기서도 확인해 두는 편이 안전하다.
   EnsureParentDir(c.logFile);
   EnsureParentDir(c.heartbeat);

   if (!c.logFile.empty()) {
      gLog.open(c.logFile.c_str(), std::ios::app);
      if (!gLog.is_open())
         std::cerr << "[WARN] cannot open log : " << c.logFile << std::endl;
   }

   // 지난 감시자가 죽으며 남긴 대기 상태 파일을 지운다 (지금은 대기가 아니다)
   ClearSupState(c);

   ::signal(SIGINT,  OnSig);
   ::signal(SIGTERM, OnSig);
   ::signal(SIGUSR1, OnUsr1);
   ::signal(SIGPIPE, SIG_IGN);
   ::signal(SIGHUP,  SIG_IGN);

   char hdr[512];
   Log("==================== rcsupervisor start ====================");
   snprintf(hdr, sizeof(hdr), "rcterm=%s  params=%s",
            c.rcterm.c_str(),
            c.rctermParams.empty() ? "(none)" : c.rctermParams.c_str());
   Log(hdr);
   snprintf(hdr, sizeof(hdr),
            "rotation=%.4f h  check=%.0f s  stale=%.0f s  grace=%.0f s  maxCycles=%d",
            c.runLengthHour, c.checkPeriodSec, c.staleLimitSec, c.graceSec, c.maxCycles);
   Log(hdr);
   snprintf(hdr, sizeof(hdr), "heartbeat=%s  bindir=%s  tcb=%s:%d",
            c.heartbeat.c_str(),
            c.binDir.empty() ? "(unset)" : c.binDir.c_str(),
            c.daqIP.c_str(), c.daqPort);
   Log(hdr);

   //  알람·복구가 실제로 걸렸는지 기동할 때 눈으로 확인할 수 있어야 한다.
   //  설정 파일에 적어 두고도 오타 하나로 조용히 꺼져 있으면, 정작 필요한
   //  순간에 아무 일도 일어나지 않는다.
   snprintf(hdr, sizeof(hdr), "notify=%s  recover=%s%s",
            c.notifyCmd.empty()  ? "(off)" : c.notifyCmd.c_str(),
            (!c.autoRecover || c.recoverCmd.empty())
                                 ? "(off)" : c.recoverCmd.c_str(),
            c.notifyParams.empty() ? "" : "  (params set)");
   Log(hdr);
   if (!c.notifyCmd.empty() && ::access(c.notifyCmd.c_str(), X_OK) != 0)
      Log("WARN notify-cmd is not executable; events will not be reported");
   if (c.autoRecover && !c.recoverCmd.empty()
       && ::access(c.recoverCmd.c_str(), X_OK) != 0)
      Log("WARN recover-cmd is not executable; automatic USB recovery is dead");

   snprintf(hdr, sizeof(hdr),
            "autonomy : standby=%s(retry %.1f min)  early-recover=%s  dram-check=%s(%d)  "
            "max-rate=%.0f Hz x%d/%.0fs  cooldown=%.0f s  rate-stops %d/%.0f s  no-events-limit=%d",
            c.standbyEnable ? "on" : "off", c.standbyRetryMin,
            c.earlyRecover ? "on" : "off", c.dramCheck ? "on" : "off", c.dramLines,
            c.maxRate, c.rateConsec, c.ratePollSec, c.rateCooldownSec,
            c.rateStopLimit, c.rateWindowSec, c.noEventsLimit);
   Log(hdr);
   snprintf(hdr, sizeof(hdr), "daq logs : %s  (old : %s)",
            c.daqLogDir.c_str(), c.daqLogDirOld.empty() ? "-" : c.daqLogDirOld.c_str());
   Log(hdr);

   const double rotateSec = c.runLengthHour * 3600.0;
   int cycle = 0, consecFail = 0, nRestart = 0;
   int  standby      = SB_NONE;          // 지금 대기 중인가, 무슨 까닭인가
   bool earlyTried   = false;            // 이번 실패 연쇄에서 조기 복구를 이미 불렀나
   std::deque<time_t> rateStops;         // 계수율 때문에 마감한 시각 (SIGUSR1 은 넣지 않는다)
   std::string lastRun;                  // 마지막으로 본 run 번호 (알림용)
   bool fatalSent     = false;           // 한 사건 연쇄에 fatal 은 한 번 (건강한 런이 나오면 풀린다)
   bool pendingRecov  = false;           // 대기에서 재개한 확인 런이 부팅을 통과하면 recovered
   std::string pendingWhat;
   bool skipNextLimitRecover = false;    // 대기에서 막 recover 를 불렀다 -> 확인 런 실패에 또 부르지 않는다
   int  zeroRuns = 0;                    // 사건이 한 번도 없던 런이 연속 몇 개인가 (totev stuck at 0)
   bool sbNoEvents = false;              // 지금 대기는 사건 0 런 연속 때문이다 -> 대기 중 recover 에 --no-events
   bool noEvRecoverDone = false;         // 대기에서 막 --no-events recover 를 불렀다 -> 확인 런 실패에 또 부르지 않는다
   bool noEvSent = false;                // 이 사건 연쇄에 no_events 를 이미 알렸다

   //  fatal 을 한 연쇄에 한 번만 낸다 (전문가 목록이 받는 메일이다)
   auto FatalOnce = [&](const std::string& run, const std::string& msg) {
      if (fatalSent) { Log("fatal already reported in this incident; not repeated"); return; }
      fatalSent = true;
      Notify(c, "fatal", run, msg);
   };

   while (!gStop) {
      // ---- 대기-재시도 모드 ----------------------------------------------
      if (standby != SB_NONE) {
         const int runProbe = c.startRun + cycle;      // --no-db 일 때 dry-run 에 쓸 번호
         std::string what;
         const int how = Standby(c, standby, lastRun, runProbe, what,
                                 sbNoEvents ? " --no-events" : "");
         if (how == 0) break;                          // SIGTERM
         if (standby == SB_CONFIG || how == 2) consecFail = 0;   // 고쳐졌다고 본다
         else consecFail = (c.maxConsecFail > 0) ? c.maxConsecFail - 1 : 0;   // 한 번만 시험
         // 사건 0 때문에 들어간 대기 : 확인 런이 또 사건 0 이면 곧바로 대기로 (limit-1 을 남긴다)
         zeroRuns = (sbNoEvents && how != 2 && c.noEventsLimit > 0) ? c.noEventsLimit - 1 : 0;
         noEvRecoverDone = sbNoEvents && how == 3;   // 대기에서 막 recover 를 불렀다
         if (how == 2) sbNoEvents = false;
         // 확인 런 : 실패하면 곧바로 대기로 돌아간다. 조기 recover 도 다시 부르지 않는다
         earlyTried = (standby == SB_HARDWARE && how != 2);
         skipNextLimitRecover = (how == 3);
         if (standby == SB_RATE) {
            // 확인 런이 다시 폭주하면 첫 마감에서 바로 대기로 (limit-1 개를 남긴다)
            rateStops.clear();
            const time_t t = time(0);
            for (int k = 0; k < c.rateStopLimit - 1; ++k) rateStops.push_back(t);
         }
         // recover 0 이면 복구 스크립트가 이미 recovered 를 알렸다
         if (how != 2) {
            pendingRecov = true;
            char pb[256];
            snprintf(pb, sizeof(pb), "대기-재시도 모드(%s)를 벗어난 확인 런이 부팅·DRAM 점검을 통과하고 사건이 들어온다 (%s)",
                     SBName(standby), what.c_str());
            pendingWhat = pb;
         }
         standby = SB_NONE;
      }

      if (c.maxCycles > 0 && cycle >= c.maxCycles) {
         Log("max cycles reached; stopping");
         break;
      }
      ++cycle;

      // 새 런 번호 : DB 를 쓰면 rcterm 이 INSERT 로 획득,
      //             --no-db 면 감시자가 직접 증가시킨다.
      const int runNoDB = c.startRun + (cycle - 1);

      gUsr1 = 0;                       // cooldown 중에 온 SIGUSR1 이 새 런을 곧바로 죽이지 않게
      const time_t launch = time(0);
      const pid_t  pid    = SpawnRcterm(c, cycle, runNoDB);
      const bool   limitRecoverDone = skipNextLimitRecover;
      skipNextLimitRecover = false;
      if (c.dryRun) {
         Log("dry-run: stopping after showing the first launch");
         break;
      }
      if (pid <= 0) {
         ++consecFail;
         Log("cannot spawn rcterm; backing off");
         SleepFor(c.failBackoffSec);
         if (c.maxConsecFail > 0 && consecFail >= c.maxConsecFail) {
            if (!c.standbyEnable) {
               Log("too many consecutive failures; aborting");
               return 2;
            }
            Log("too many consecutive spawn failures; entering standby");
            FatalOnce(lastRun, "rcterm 을 띄우지 못한다 - 대기-재시도 모드로 간다");
            standby = SB_HARDWARE;
         }
         continue;
      }

      HealthState hs;
      time_t lastCheck = launch, lastPoll = launch;
      bool   unhealthy = false, rotated = false, childGone = false, selfExit = false;
      bool   dramDone  = !c.dramCheck, dramFail = false;
      bool   rateStop  = false, usr1Stop = false;
      int    rateHits  = 0;
      int    status = 0;
      std::string reason, cycRun;
      if (!c.useDB) cycRun = std::to_string(runNoDB);

      // ---------------- 감시 루프 ----------------
      while (true) {
         ::sleep(1);

         if (gStop) {
            Log("stop requested; ending the current run gracefully");
            bool g = false;
            status = StopRcterm(pid, c.graceSec, g);
            childGone = true;
            break;
         }

         if (gUsr1) {
            gUsr1 = 0;
            snprintf(hdr, sizeof(hdr),
                     "SIGUSR1 : ending the current run gracefully; relaunch after %.0f s",
                     c.rateCooldownSec);
            Log(hdr);
            bool g = false;
            status = StopRcterm(pid, c.graceSec, g);
            childGone = true;
            usr1Stop  = true;
            reason    = "external request (SIGUSR1)";
            break;
         }

         const pid_t r = ::waitpid(pid, &status, WNOHANG);
         if (r == pid) { childGone = true; selfExit = true; break; }

         const time_t now = time(0);

         // 로테이션 시각 도달 -> 정상 종료 지시
         if ((double)(now - launch) >= rotateSec) {
            char b[160];
            snprintf(b, sizeof(b),
                     "rotation time reached (%.4f h); ending run gracefully",
                     c.runLengthHour);
            Log(b);
            bool g = false;
            status = StopRcterm(pid, c.graceSec, g);
            childGone = true;
            rotated   = true;
            if (!g) Log("WARN graceful end failed during rotation");
            break;
         }

         // ---- 빠른 점검 : 이 rcterm 이 쓴 heartbeat 만 믿는다 (pid 일치) ----
         if ((double)(now - lastPoll) >= c.ratePollSec) {
            lastPoll = now;
            std::map<std::string, std::string> hb;
            const bool trusted = ReadHB(c.heartbeat, hb)
                && atoll(HBGet(hb, "pid", "0").c_str()) == (long long)pid
                && atoll(HBGet(hb, "time", "0").c_str()) >= (long long)launch
                && (double)(now - (time_t)atoll(HBGet(hb, "time", "0").c_str())) < c.staleLimitSec;
            if (!trusted) rateHits = 0;          // 못 읽은 회차는 '연속' 을 끊는다
            if (trusted) {
               const std::string hr = HBGet(hb, "run", "");
               if (!hr.empty()) cycRun = hr;
               const bool running = HBGet(hb, "phase", "") == "running";

               // S-3 : 부팅 뒤 DRAM 정렬 (pkill 복구 뒤 미정렬 런이 24 h 돈 적이 있다, 11.208)
               if (running && !dramDone && (double)(now - launch) >= c.bootGraceSec) {
                  dramDone = true;
                  const std::string tlog = FindDaqLog(c, "TCB", cycRun);
                  if (tlog.empty()) {
                     Log("WARN DRAM check skipped : TCB log for run " + cycRun + " not found");
                  } else {
                     const int na = CountLines(tlog, IsAligned);
                     const int nf = CountLines(tlog, IsAlignFail);
                     snprintf(hdr, sizeof(hdr), "DRAM check run=%s : is aligned %d / %d, Fail to align %d  (%s)",
                              cycRun.c_str(), na, c.dramLines, nf, tlog.c_str());
                     Log(hdr);
                     if (na != c.dramLines || nf != 0) {
                        snprintf(hdr, sizeof(hdr), "DRAM not aligned (is aligned %d/%d, Fail to align %d)",
                                 na, c.dramLines, nf);
                        reason = hdr;
                        Log("UNHEALTHY : " + reason);
                        bool g = false;
                        status    = StopRcterm(pid, c.graceSec, g);
                        childGone = true;
                        unhealthy = true;
                        dramFail  = true;
                        break;
                     }
                  }
               }

               // S-4 : 순간 계수율 상한 (ar 이 아니라 sr. 4423 09:24 41.7 kHz, 11.227)
               if (running && c.maxRate > 0) {
                  const double sr = MaxSR(hb);
                  if (sr >= c.maxRate) {
                     ++rateHits;
                     snprintf(hdr, sizeof(hdr), "rate high run=%s : max sr %.0f Hz >= %.0f (%d/%d)",
                              cycRun.c_str(), sr, c.maxRate, rateHits, c.rateConsec);
                     Log(hdr);
                     if (rateHits >= c.rateConsec) {
                        snprintf(hdr, sizeof(hdr),
                                 "계수율 비정상 : 순간 %.0f Hz >= %.0f Hz 가 연속 %d 회 - 런을 정상 마감",
                                 sr, c.maxRate, rateHits);
                        reason = hdr;
                        bool g = false;
                        status    = StopRcterm(pid, c.graceSec, g);
                        childGone = true;
                        rateStop  = true;
                        break;
                     }
                  } else {
                     rateHits = 0;
                  }
               }

               // 부팅·DRAM 점검을 통과했고 계수율도 상한 아래이고 사건이 들어온다 -> 사건 연쇄가 끝났다고 본다
               //  ★ totev 가 0 이면 아니다 (2026-11-08 run 4445 : 부팅·DRAM 만 보고 recovered 를 전문가 13 명에게
               //    보냈는데 사건은 0 이었다)
               const unsigned long long tv = strtoull(HBGet(hb, "totev", "0").c_str(), 0, 10);
               if (tv > 0) hs.sawEvents = true;
               if (running && dramDone && rateHits == 0 && tv > 0
                   && (double)(now - launch) >= c.bootGraceSec) {
                  zeroRuns = 0; noEvSent = false; sbNoEvents = false;
                  if (pendingRecov) {
                     pendingRecov = false;
                     Notify(c, "recovered", cycRun, pendingWhat);
                  }
                  fatalSent = false;
               }
            }
         }

         // 주기적 진단
         if ((double)(now - lastCheck) >= c.checkPeriodSec) {
            lastCheck = now;
            if (CheckHealth(c, launch, hs, reason)) {
               std::map<std::string, std::string> hb;
               ReadHB(c.heartbeat, hb);
               char b[256];
               snprintf(b, sizeof(b),
                        "health OK  run=%s sub=%s state=%s totev=%s",
                        HBGet(hb, "run", "?").c_str(),
                        HBGet(hb, "subrun", "?").c_str(),
                        HBGet(hb, "state", "?").c_str(),
                        HBGet(hb, "totev", "?").c_str());
               Log(b);
            } else {
               Log("UNHEALTHY : " + reason);
               bool g = false;
               status    = StopRcterm(pid, c.graceSec, g);
               childGone = true;
               unhealthy = true;
               break;
            }
         }
      }

      if (!childGone) ::waitpid(pid, &status, 0);

      // 이 rcterm 이 마지막으로 쓴 run 번호 (실패해도 heartbeat 에 남아 있으면)
      {
         std::map<std::string, std::string> hb;
         if (ReadHB(c.heartbeat, hb)
             && atoll(HBGet(hb, "pid", "0").c_str()) == (long long)pid
             && !HBGet(hb, "run", "").empty())
            cycRun = HBGet(hb, "run", "");
      }
      if (!cycRun.empty()) lastRun = cycRun;

      const bool exitedOK = WIFEXITED(status) && WEXITSTATUS(status) == 0;
      const int  exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
      char b[256];
      snprintf(b, sizeof(b), "cycle %d finished : exit=%s%s%s%s%s",
               cycle,
               WIFEXITED(status)
                  ? ("code " + std::to_string(WEXITSTATUS(status))).c_str()
                  : (WIFSIGNALED(status)
                        ? ("signal " + std::to_string(WTERMSIG(status))).c_str()
                        : "unknown"),
               rotated   ? "  (rotation)"  : "",
               unhealthy ? "  (unhealthy)" : "",
               rateStop  ? "  (rate stop)" : "",
               usr1Stop  ? "  (SIGUSR1)"   : "");
      Log(b);

      if (gStop) break;

      // ---- S-4 : 계수율 상한 / SIGUSR1 마감 --------------------------------
      if (rateStop || usr1Stop) {
         if (hs.sawEvents) zeroRuns = 0;
         if (rateStop) Notify(c, "rate_high", cycRun, reason);
         // 포화 런의 마감 읽기에는 TIMEOUT 이 따르고, 그 뒤 부팅은 OVERFLOW 로 죽는다 (11.223)
         std::string where;
         const int nClose = ScanRunLogs(c, cycRun, IsCloseErr, where);
         if (!exitedOK || nClose > 0) {
            snprintf(b, sizeof(b), "after the stop : exit ok=%d, TIMEOUT/OVERFLOW %d (%s)",
                     exitedOK ? 1 : 0, nClose, where.empty() ? "-" : where.c_str());
            Log(b);
            CleanupStale(c);
            SleepFor(c.settleSec);
            if (c.autoRecover && !c.recoverCmd.empty()) {
               const int rrc = RunRecover(c);
               snprintf(b, sizeof(b), "recovery after the stop returned %d", rrc);
               Log(b);
            }
         }
         const time_t now = time(0);
         if (rateStop) rateStops.push_back(now);      // SIGUSR1 은 세지 않는다
         while (!rateStops.empty() && (double)(now - rateStops.front()) > c.rateWindowSec)
            rateStops.pop_front();
         if ((int)rateStops.size() >= c.rateStopLimit) {
            snprintf(b, sizeof(b), "%d rate stops within %.0f s; entering standby",
                     (int)rateStops.size(), c.rateWindowSec);
            Log(b);
            if (!c.standbyEnable) { Log("FATAL rate stops limit (no standby); giving up"); return 2; }
            snprintf(b, sizeof(b), "계수율 때문에 %.0f 분 안에 %d 번 마감 - 대기-재시도 모드로 간다",
                     c.rateWindowSec / 60.0, (int)rateStops.size());
            FatalOnce(cycRun, b);
            standby = SB_RATE;
            continue;
         }
         snprintf(b, sizeof(b), "cooldown %.0f s before relaunch (rate stops %d/%d in window)",
                  c.rateCooldownSec, (int)rateStops.size(), c.rateStopLimit);
         Log(b);
         SleepFor(c.rateCooldownSec);
         consecFail = 0;
         continue;
      }

      // ---- S-1 : 설정 오류는 재시작해도 소용없다 ------------------------------
      if (selfExit && exitCode == 1) {
         Log("rcterm exit 1 = configuration error; restart is pointless");
         FatalOnce(cycRun, "config error, restart pointless (rcterm exit 1)");
         if (!c.standbyEnable) {
            Log("FATAL configuration error (no standby); giving up");
            return 1;
         }
         standby = SB_CONFIG;
         continue;
      }

      if (unhealthy || !exitedOK) {
         ++consecFail;
         ++nRestart;

         Log("recovering : cleaning up stale DAQ processes");
         CleanupStale(c);
         SleepFor(c.settleSec);
         snprintf(b, sizeof(b),
                  "restart #%d (consecutive failures %d/%d); next run will be new",
                  nRestart, consecFail, c.maxConsecFail);
         Log(b);

         // ---- 사건이 한 번도 없던 런 (totev 가 시작부터 0) 이 연속 : 5 번을 다 태우지 않는다 ----
         //  2026-11-08 : 09:23 전원 재투입 뒤 부팅·DRAM·USB 정상인데 트리거 0 인 런 5 개(약 4 h).
         //  원인은 보드가 트리거를 못 내는 상태로 올라온 것이었고 두 번째 전원 재투입(15:42)이 풀었다.
         //  -> no_events 알림 + recover --no-events (usb-recover 가 전원 재투입까지 한다, 6 h 2 회 상한은 그쪽)
         const bool noEvRun = unhealthy && !hs.sawEvents
                              && reason.find("totev stuck at 0") != std::string::npos;
         zeroRuns = noEvRun ? zeroRuns + 1 : 0;
         if (noEvRun && c.noEventsLimit > 0 && zeroRuns >= c.noEventsLimit) {
            snprintf(b, sizeof(b),
                     "%d runs in a row never saw an event (totev stuck at 0); no_events",
                     zeroRuns);
            Log(b);
            if (!noEvSent) {
               snprintf(b, sizeof(b),
                        "사건 0 인 런이 연속 %d 개 (run %s, 부팅·DRAM 정상, totev 0). "
                        "보드가 트리거를 못 내는 상태일 수 있어 전원 재투입까지 자동 복구를 부른다",
                        zeroRuns, cycRun.c_str());
               Notify(c, "no_events", cycRun, b);
               noEvSent = true;
            }
            int rrc = 1;
            if (noEvRecoverDone) {
               Log("no_events on a probe run right after standby recovery - recover not repeated");
            } else if (c.autoRecover && !c.recoverCmd.empty()) {
               rrc = RunRecover(c, " --no-events");
               snprintf(b, sizeof(b), "automatic recovery (--no-events) returned %d "
                        "(0=recovered 1=not-usb 2=failed 3=unsafe)", rrc);
               Log(b);
            }
            noEvRecoverDone = false;
            if (rrc == 0) {
               Log("automatic recovery succeeded; resuming data taking");
               consecFail = 0; zeroRuns = 0; earlyTried = false;
               SleepFor(c.settleSec);
               continue;
            }
            if (!c.standbyEnable) { Log("FATAL no events (no standby); giving up"); return 2; }
            Log("still no events; entering standby (hardware)");
            if (rrc == 2) fatalSent = true;     // recover 가 recovery_failed 로 이미 알렸다
            else FatalOnce(cycRun, "사건 0 런 연속, 자동 복구로 안 풀림 -- 전자계 정상·트리거 0 : "
                                   "PMT HV·케이블·앞단 전원 확인 (CLAUDE.md 11.131). 대기-재시도 모드로 간다");
            standby = SB_HARDWARE;
            sbNoEvents = true;
            consecFail = 0;
            continue;
         }

         // heartbeat 가 멈춰서 잡힌 것과 그냥 실패한 것은 성격이 다르다.
         // 앞은 '쓰다가 멎었다', 뒤는 '아예 못 떴다' 인 경우가 많다.
         const bool wasStale = reason.find("stale") != std::string::npos;
         Notify(c, wasStale ? "stale" : "restart", cycRun,
                reason.empty() ? std::string(b) : reason);

         // ---- S-2 / S-3 : 근거가 있으면 한도를 기다리지 않고 바로 복구 ----
         //  실측 : USB 서명이 첫 실패부터 분명한데 런 4 개를 더 태웠다 (4424~4427, 4335~4339)
         int earlyRrc = -1000;                  // 이 실패에서 조기 recover 를 불렀으면 그 값
         if (c.autoRecover && !c.recoverCmd.empty() && c.earlyRecover && !earlyTried) {
            std::string where;
            const int nSig = dramFail ? 0 : ScanRunLogs(c, cycRun, IsUsbSig, where);
            if (dramFail || nSig > 0) {
               earlyTried = true;
               snprintf(b, sizeof(b), "%s; trying automatic recovery now",
                        dramFail ? "DRAM not aligned"
                                 : ("USB signature in run " + cycRun + " logs (" + where + ")").c_str());
               Log(b);
               const int rrc = RunRecover(c);
               earlyRrc = rrc;
               snprintf(b, sizeof(b), "automatic recovery returned %d "
                        "(0=recovered 1=not-usb 2=failed 3=unsafe)", rrc);
               Log(b);
               if (rrc == 0) {
                  Log("automatic recovery succeeded; resuming data taking");
                  consecFail = 0;
                  earlyTried = false;
                  SleepFor(c.settleSec);
                  continue;
               }
            }
         }

         if (c.maxConsecFail > 0 && consecFail >= c.maxConsecFail) {
            // ---- 포기하기 전에 자동 USB 복구를 한 번 시도한다 ----
            //  2026-08-20 에 FADC 보드가 걸려 런 5개가 연속 실패했다. 그때
            //  사람이 한 일(진단 -> usbreset -> 짧은 확인 런)을 스크립트로
            //  옮겨 두었다. 여기서 그것을 부른다.
            //  ★ 복구 판단과 실행은 전부 바깥 스크립트에 있다. 감시자는
            //    종료코드만 보고 이어갈지 대기할지 정한다.
            int rrc = -1;
            //  같은 실패에서 조기 recover 를 이미 불렀거나, 대기에서 막 recover 를 부르고
            //  띄운 확인 런이면 또 부르지 않는다 (recover 가 3 번 연달아 도는 것을 막는다)
            if (earlyRrc != -1000) {
               rrc = earlyRrc;
               Log("limit reached; recovery already tried for this failure - not repeated");
            } else if (limitRecoverDone) {
               rrc = 1;
               Log("limit reached on a probe run right after standby recovery - not repeated");
            } else if (c.autoRecover && !c.recoverCmd.empty()) {
               Log("consecutive failure limit reached; trying automatic USB recovery");
               rrc = RunRecover(c);
               snprintf(b, sizeof(b), "automatic recovery returned %d "
                        "(0=recovered 1=not-usb 2=failed 3=unsafe)", rrc);
               Log(b);
               if (rrc == 0) {
                  Log("automatic USB recovery succeeded; resuming data taking");
                  consecFail = 0;               // 새로 세기 시작한다
                  earlyTried = false;
                  SleepFor(c.settleSec);
                  continue;                     // 다음 사이클로 그냥 간다
               }
            }

            // 복구 스크립트가 이미 recovery_failed 로 알렸으면 또 보내지 않는다.
            // 그쪽 메일이 시도 기록까지 담고 있어 훨씬 쓸모 있다.
            if (!c.standbyEnable) {
               Log("FATAL too many consecutive failures; giving up. "
                   "please inspect the DAQ logs");
               if (rrc != 1 && rrc != 2)
                  Notify(c, "fatal", cycRun,
                         "연속 실패 한계 도달 - 감시자가 종료한다");
               return 2;
            }
            Log("too many consecutive failures; entering standby (retry later). "
                "please inspect the DAQ logs");
            if (rrc != 1 && rrc != 2)
               FatalOnce(cycRun, "연속 실패 한계 도달 - 대기-재시도 모드로 간다");
            else
               fatalSent = true;                // recover 가 recovery_failed 로 이미 알렸다
            standby = SB_HARDWARE;
            continue;
         }
         SleepFor(c.failBackoffSec);
      } else {
         consecFail = 0;
         earlyTried = false;
         if (hs.sawEvents) zeroRuns = 0;
         SleepFor(c.settleSec);
      }
   }

   Log("==================== rcsupervisor stop =====================");
   return 0;
}
