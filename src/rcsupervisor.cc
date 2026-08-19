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
// ---------------------------------------------------------------------

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
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
static pid_t SpawnRcterm(const Sup& c, int cycle, int runForNoDB)
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
static int RunRecover(const Sup& c)
{
   if (c.recoverCmd.empty()) return -1;
   std::string cmd = c.recoverCmd;
   if (!c.notifyParams.empty()) cmd += " --params " + ShQuote(c.notifyParams);
   Log("recover: " + cmd);
   if (c.dryRun) return -1;
   int rc = ::system(cmd.c_str());
   if (rc == -1) return -1;
   return WIFEXITED(rc) ? WEXITSTATUS(rc) : -1;
}

// ============================================================== 진단
struct HealthState {
   unsigned long long lastTot = 0;
   bool   haveTot   = false;
   time_t lastAdvance = 0;
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
      else {
         std::cerr << "unknown option : " << o << std::endl;
         Usage(argv[0]);
         return 1;
      }
      #undef VAL
   }

   if (c.runLengthHour <= 0)  { std::cerr << "--run-length must be > 0" << std::endl; return 1; }
   if (c.checkPeriodSec <= 0) { std::cerr << "--check-period must be > 0" << std::endl; return 1; }
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

   ::signal(SIGINT,  OnSig);
   ::signal(SIGTERM, OnSig);
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

   const double rotateSec = c.runLengthHour * 3600.0;
   int cycle = 0, consecFail = 0, nRestart = 0;

   while (!gStop) {
      if (c.maxCycles > 0 && cycle >= c.maxCycles) {
         Log("max cycles reached; stopping");
         break;
      }
      ++cycle;

      // 새 런 번호 : DB 를 쓰면 rcterm 이 INSERT 로 획득,
      //             --no-db 면 감시자가 직접 증가시킨다.
      const int runNoDB = c.startRun + (cycle - 1);

      const time_t launch = time(0);
      const pid_t  pid    = SpawnRcterm(c, cycle, runNoDB);
      if (c.dryRun) {
         Log("dry-run: stopping after showing the first launch");
         break;
      }
      if (pid <= 0) {
         ++consecFail;
         Log("cannot spawn rcterm; backing off");
         ::sleep((unsigned)c.failBackoffSec);
         if (c.maxConsecFail > 0 && consecFail >= c.maxConsecFail) {
            Log("too many consecutive failures; aborting");
            return 2;
         }
         continue;
      }

      HealthState hs;
      time_t lastCheck = launch;
      bool   unhealthy = false, rotated = false, childGone = false;
      int    status = 0;
      std::string reason;

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

         const pid_t r = ::waitpid(pid, &status, WNOHANG);
         if (r == pid) { childGone = true; break; }

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

      const bool exitedOK = WIFEXITED(status) && WEXITSTATUS(status) == 0;
      char b[256];
      snprintf(b, sizeof(b), "cycle %d finished : exit=%s%s%s",
               cycle,
               WIFEXITED(status)
                  ? ("code " + std::to_string(WEXITSTATUS(status))).c_str()
                  : (WIFSIGNALED(status)
                        ? ("signal " + std::to_string(WTERMSIG(status))).c_str()
                        : "unknown"),
               rotated   ? "  (rotation)"  : "",
               unhealthy ? "  (unhealthy)" : "");
      Log(b);

      if (gStop) break;

      if (unhealthy || !exitedOK) {
         ++consecFail;
         ++nRestart;

         // 어느 런이 죽었는지는 heartbeat 에서 읽는다. 알림 본문에 들어간다.
         std::map<std::string, std::string> hbNow;
         ReadHB(c.heartbeat, hbNow);
         const std::string curRun = HBGet(hbNow, "run", "");

         Log("recovering : cleaning up stale DAQ processes");
         CleanupStale(c);
         ::sleep((unsigned)c.settleSec);
         snprintf(b, sizeof(b),
                  "restart #%d (consecutive failures %d/%d); next run will be new",
                  nRestart, consecFail, c.maxConsecFail);
         Log(b);

         // heartbeat 가 멈춰서 잡힌 것과 그냥 실패한 것은 성격이 다르다.
         // 앞은 '쓰다가 멎었다', 뒤는 '아예 못 떴다' 인 경우가 많다.
         const bool wasStale = reason.find("stale") != std::string::npos;
         Notify(c, wasStale ? "stale" : "restart", curRun,
                reason.empty() ? std::string(b) : reason);

         if (c.maxConsecFail > 0 && consecFail >= c.maxConsecFail) {
            // ---- 포기하기 전에 자동 USB 복구를 한 번 시도한다 ----
            //  2026-08-20 에 FADC 보드가 걸려 런 5개가 연속 실패했다. 그때
            //  사람이 한 일(진단 -> usbreset -> 짧은 확인 런)을 스크립트로
            //  옮겨 두었다. 여기서 그것을 부른다.
            //  ★ 복구 판단과 실행은 전부 바깥 스크립트에 있다. 감시자는
            //    종료코드만 보고 이어갈지 포기할지 정한다.
            int rrc = -1;
            if (c.autoRecover && !c.recoverCmd.empty()) {
               Log("consecutive failure limit reached; trying automatic USB recovery");
               rrc = RunRecover(c);
               snprintf(b, sizeof(b), "automatic recovery returned %d "
                        "(0=recovered 1=not-usb 2=failed 3=unsafe)", rrc);
               Log(b);
               if (rrc == 0) {
                  Log("automatic USB recovery succeeded; resuming data taking");
                  consecFail = 0;               // 새로 세기 시작한다
                  ::sleep((unsigned)c.settleSec);
                  continue;                     // 다음 사이클로 그냥 간다
               }
            }

            Log("FATAL too many consecutive failures; giving up. "
                "please inspect the DAQ logs");
            // 복구 스크립트가 이미 recovery_failed 로 알렸으면 또 보내지 않는다.
            // 그쪽 메일이 시도 기록까지 담고 있어 훨씬 쓸모 있다.
            if (rrc != 1 && rrc != 2)
               Notify(c, "fatal", curRun,
                      "연속 실패 한계 도달 - 감시자가 종료한다");
            return 2;
         }
         ::sleep((unsigned)c.failBackoffSec);
      } else {
         consecFail = 0;
         ::sleep((unsigned)c.settleSec);
      }
   }

   Log("==================== rcsupervisor stop =====================");
   return 0;
}
