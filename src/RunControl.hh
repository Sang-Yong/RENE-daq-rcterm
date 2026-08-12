#ifndef RunControl_hh
#define RunControl_hh 1

#include <csignal>
#include <ctime>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "TString.h"
#include "OnlSocket.hh"

class TFile;
class TTree;

// config 파일의 SERVER 라인 하나
struct DaqNode {
   int         mode;      // 0=TCB, 1=ADC, 2=MERGER
   int         dnum;      // daqid
   std::string name;      // TCB / FADCDAQ / SADCDAQ / FADCMERGER / SADCMERGER ...
   std::string ip;
   int         port;
   char        letter;    // f s i g m a : daq/merger 의 ADC 종류 플래그
   std::string kind;      // FADC / SADC / IADC / GADC / MADC / AADC
   bool        dosend;    // -x : 같은 종류의 merger 가 있는 ADC
   DaqNode() : mode(1), dnum(0), port(0), letter(0), dosend(false) {}
};

// DAQ 별 트리거 통계
struct TrgStat {
   unsigned long long n, pn;   // 누적 / 직전 이벤트 수
   double             t, pt;   // 누적 / 직전 시간 [s]
   double             ar, sr;  // 평균 / 순간 rate [Hz]
   TrgStat() : n(0), pn(0), t(0), pt(0), ar(0), sr(0) {}
};

class RunControl {
public:
   enum { kMaxDaq = 16 };

   struct Config {
      // ---- 런 정보 (초기 입력값) ----
      std::string shift;
      std::string runtype;
      std::string rundesc;
      std::string configFile;
      int         splitTimeMin;    // 서브런 분할 [분] -> TCB 에 -p <초>
      bool        tcbSplit;        // -p 를 실제로 붙일지
      double      runLengthHour;   // 런 1개 길이 [시간]
      int         maxRuns;         // 0 = 무한
      int         startRun;        // --no-db 시 시작 번호
      bool        useDB;
      bool        goodRun;
      char        mergerType;      // merger 이름에 종류가 없을 때 강제 지정
      // ---- 동작 ----
      double      updateSec;
      bool        quiet;
      bool        dryRun;
      double      bootTimeout;
      double      stateTimeout;
      std::string logFile;
      std::string rootFile;
      std::string heartbeatFile;   // 외부 감시자용 상태 파일
      // ---- 사이트 ----
      std::string daqServerIP;
      int         daqServerPort;
      std::string onldaqDir;
      std::string rawdataDir;
      std::string dbFile;
      std::string binDir;
      std::string exeScript;

      Config()
        : runtype("physics"), splitTimeMin(1), tcbSplit(true),
          runLengthHour(24.0), maxRuns(0), startRun(0),
          useDB(true), goodRun(true), mergerType(0),
          updateSec(1.0), quiet(false), dryRun(false),
          bootTimeout(90.0), stateTimeout(60.0),
          daqServerIP(RCTERM_DEF_SERVER_IP),
          daqServerPort(RCTERM_DEF_SERVER_PORT),
          onldaqDir(RCTERM_DEF_ONLDAQ_DIR),
          rawdataDir(RCTERM_DEF_RAWDATA_DIR),
          dbFile(RCTERM_DEF_DBFILE),
          exeScript(RCTERM_DEF_EXESCRIPT) {}
   };

   explicit RunControl(const Config& c);
   ~RunControl();

   bool Init();
   int  Execute();

   static void RequestStop() { fgStop = 1; }
   static bool Stopping()    { return fgStop != 0; }

private:
   bool RunOneCycle(int run, int cycle);
   bool BootRun(int run);
   bool OpenTCB();
   bool SetupMonitors();
   void CloseMonitors();
   bool SendCmd(unsigned long long cmd, const char* what);
   bool WaitState(int state, double timeoutSec);
   unsigned long long QueryStatus();
   void QueryRunInfo();
   void UpdateStats(bool finalRead);
   unsigned long long TotalEvents() const;

   void PrintScreen(int run, int cycle, double remain);
   void PrintLine(int run, int cycle);
   void WriteHeartbeat(int run, const char* phase);
   void FillTree(int run);
   void Log(const std::string& s);

   bool ParseConfigFile();
   bool ResolveKinds();
   int  NextRunNumberFromDB();
   void FinalizeRunInDB(int run);
   bool LoadDBColumns();
   bool HasColumn(const std::string& c) const;
   TString RunSQL(const std::string& sql);

   Config                   fCfg;
   std::vector<DaqNode>     fNodes;      // MERGER -> ADC -> TCB 순
   std::string              fRunConfig;  // <rawdata>/CONFIG/%06d.config
   std::vector<std::string> fDBColumns;

   OnlSocket*                     fTCB;
   std::vector<std::string>       fMonNames;
   std::vector<std::string>       fMonKinds;
   std::vector<OnlSocket*>        fMonSocks;
   std::map<std::string, TrgStat> fStats;

   unsigned long long fStatus, fSubRun, fStartTime, fEndTime;
   time_t             fRunStartWall;

   std::ofstream fLog;
   TFile*  fRootFile;
   TTree*  fTree;
   int     bRun, bSubRun, bNDaq, bState;
   double  bCTime, bDaqTime;
   long long bNev[kMaxDaq];
   double  bSRate[kMaxDaq], bARate[kMaxDaq];

   static volatile sig_atomic_t fgStop;
};

#endif
