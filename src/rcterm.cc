// ---------------------------------------------------------------------
//  rcterm : RENE / CUPDAQ text-mode run control  (CERN ROOT / C++)
//
//  DAQRC/rc.py 의 PyQt5 GUI 를 제거하고 스크립트 입출력이 가능한 통식으로
//  재작성한 프로그램. 단일 PC 구성(kISREMOTEDAQ=False) 전용이부
//  ssh/scp 를 사용하지 않는다.
//
//  런 로테이션은 다음 두 가지 방법이 있다.
//    (a) rcterm 자체 로테이션  : --run-length 24 --max-runs 0
//    (b) rcsupervisor 가 관리  : rcterm 은 --max-runs 1 로 한 런만 수행
//        (권장. 에러 감지/자동 복관이 함족된다)
// ---------------------------------------------------------------------

#include <csignal>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "TSystem.h"
#include "RunControl.hh"

static void OnSignal(int) { RunControl::RequestStop(); }

static void Usage(const char* p)
{
   std::cout <<
"\nUsage: " << p << " [OPTIONS]\n"
"       " << p << " --params <file> [OPTIONS]\n"
"\n"
" Run information (rc.py GUI 입력항에 1:1 대원)\n"
"   --shift NAME          shift crew name                        [required]\n"
"   --config FILE         hardware config file (*.config)        [required]\n"
"   --runtype TYPE        physics | calibration | test            (physics)\n"
"   --desc \"TEXT\"         run description memo\n"
"\n"
" Timing\n"
"   --split-time MIN      subrun split time [min] -> TCB '-p <sec>'     (1)\n"
"   --no-tcb-split        do not pass -p (use TCB built-in default)\n"
"   --run-length HOUR     length of one run before rotation            (24)\n"
"   --max-runs N          stop after N runs, 0 = unlimited              (0)\n"
"\n"
" Run catalog\n"
"   --dbfile FILE         runcatalog.db           (" RCTERM_DEF_DBFILE ")\n"
"   --no-db               do not touch DB; requires --run\n"
"   --run N               start run number for --no-db\n"
"   --badrun              record onlbit=0 instead of 1\n"
"\n"
" Site\n"
"   --daqserver IP        TCB host                     (" RCTERM_DEF_SERVER_IP ")\n"
"   --daqport PORT        TCB port                                  (7809)\n"
"   --onldaqdir DIR       (" RCTERM_DEF_ONLDAQ_DIR ")\n"
"   --rawdatadir DIR      (" RCTERM_DEF_RAWDATA_DIR ")\n"
"   --bindir DIR          dir holding executedaq.sh    (ONLDAQDIR/bin)\n"
"   --exescript NAME      (executedaq.sh)\n"
"   --merger-type L       f|s|i|g|m  only when a merger name lacks\n"
"                         its ADC kind (FADCMERGER/SADCMERGER are\n"
"                         detected automatically)\n"
"\n"
" Output / misc\n"
"   --update SEC          screen update period                     (1.0)\n"
"   --quiet               one line per update (script friendly)\n"
"   --log FILE            append text log\n"
"   --heartbeat FILE      write machine-readable status for rcsupervisor\n"
"   --rootout FILE        write monitoring TTree (ROOT)\n"
"   --dry-run             print every command, touch no hardware\n"
"   --boot-timeout SEC    (90)\n"
"   --state-timeout SEC   (60)\n"
"   -h, --help\n"
"\n"
" Environment defaults: ONLDAQ_DIR RAWDATA_DIR RUNCATALOG_DB\n"
"                       DAQSERVER_IP DAQSERVER_PORT\n"
<< std::endl;
}

static std::string Trim(const std::string& s)
{
   size_t a = s.find_first_not_of(" \t\r\n\"");
   if (a == std::string::npos) return "";
   size_t b = s.find_last_not_of(" \t\r\n\"");
   return s.substr(a, b - a + 1);
}

// key=value 파일 -> argv 토큰으로 펼침
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

static std::string EnvOr(const char* n, const std::string& d)
{
   const char* v = gSystem->Getenv(n);
   return (v && *v) ? std::string(v) : d;
}

int main(int argc, char** argv)
{
   RunControl::Config cfg;

   cfg.onldaqDir     = EnvOr("ONLDAQ_DIR",    cfg.onldaqDir);
   cfg.rawdataDir    = EnvOr("RAWDATA_DIR",   cfg.rawdataDir);
   cfg.dbFile        = EnvOr("RUNCATALOG_DB", cfg.dbFile);
   cfg.daqServerIP   = EnvOr("DAQSERVER_IP",  cfg.daqServerIP);
   cfg.daqServerPort = atoi(EnvOr("DAQSERVER_PORT",
                                  std::to_string(cfg.daqServerPort)).c_str());

   // --params 를 위치 그대로 펼친다 -> 뒤에 오는 인자가 항상 이긴다.
   std::vector<std::string> a;
   for (int i = 1; i < argc; ++i) {
      const std::string s = argv[i];
      if (s == "--params") {
         if (i + 1 >= argc) { std::cerr << "--params needs FILE" << std::endl; return 1; }
         if (!LoadParams(argv[++i], a)) return 1;
      } else {
         a.push_back(s);
      }
   }
   if (a.empty()) { Usage(argv[0]); return 1; }

   for (size_t i = 0; i < a.size(); ++i) {
      const std::string o = a[i];
      const std::string v = (i + 1 < a.size()) ? a[i + 1] : "";
      #define VAL if (v.empty() || v.substr(0, 2) == "--") {                    \
                     std::cerr << o << " needs a value" << std::endl; return 1; \
                  } ++i;

      if      (o == "-h" || o == "--help") { Usage(argv[0]); return 0; }
      else if (o == "--shift")         { VAL cfg.shift = v; }
      else if (o == "--config")        { VAL cfg.configFile = v; }
      else if (o == "--runtype")       { VAL cfg.runtype = v; }
      else if (o == "--desc")          { VAL cfg.rundesc = v; }
      else if (o == "--split-time")    { VAL cfg.splitTimeMin = atoi(v.c_str()); }
      else if (o == "--no-tcb-split")  { cfg.tcbSplit = false; }
      else if (o == "--run-length")    { VAL cfg.runLengthHour = atof(v.c_str()); }
      else if (o == "--max-runs")      { VAL cfg.maxRuns = atoi(v.c_str()); }
      else if (o == "--dbfile")        { VAL cfg.dbFile = v; }
      else if (o == "--no-db")         { cfg.useDB = false; }
      else if (o == "--run")           { VAL cfg.startRun = atoi(v.c_str()); }
      else if (o == "--badrun")        { cfg.goodRun = false; }
      else if (o == "--daqserver")     { VAL cfg.daqServerIP = v; }
      else if (o == "--daqport")       { VAL cfg.daqServerPort = atoi(v.c_str()); }
      else if (o == "--onldaqdir")     { VAL cfg.onldaqDir = v; }
      else if (o == "--rawdatadir")    { VAL cfg.rawdataDir = v; }
      else if (o == "--bindir")        { VAL cfg.binDir = v; }
      else if (o == "--exescript")     { VAL cfg.exeScript = v; }
      else if (o == "--merger-type")   { VAL cfg.mergerType = v[0]; }
      else if (o == "--update")        { VAL cfg.updateSec = atof(v.c_str()); }
      else if (o == "--quiet")         { cfg.quiet = true; }
      else if (o == "--log")           { VAL cfg.logFile = v; }
      else if (o == "--heartbeat")     { VAL cfg.heartbeatFile = v; }
      else if (o == "--rootout")       { VAL cfg.rootFile = v; }
      else if (o == "--dry-run")       { cfg.dryRun = true; }
      else if (o == "--boot-timeout")  { VAL cfg.bootTimeout = atof(v.c_str()); }
      else if (o == "--state-timeout") { VAL cfg.stateTimeout = atof(v.c_str()); }
      else {
         std::cerr << "unknown option : " << o << std::endl;
         Usage(argv[0]);
         return 1;
      }
      #undef VAL
   }

   signal(SIGINT,  OnSignal);
   signal(SIGTERM, OnSignal);
   signal(SIGPIPE, SIG_IGN);     // 소켓이 닫혔다고 프로세스가 죽지 않도록

   RunControl rc(cfg);
   if (!rc.Init()) return 1;
   return rc.Execute();
}
