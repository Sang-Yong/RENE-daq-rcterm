#include "RunControl.hh"
#include "OnlConsts.hh"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>

#include "TFile.h"
#include "TNamed.h"
#include "TSystem.h"
#include "TTree.h"

volatile sig_atomic_t RunControl::fgStop = 0;

// ================================================================ utils
namespace {

std::string TimeStr(time_t t)
{
   if (t <= 0) return "-";
   char buf[64];
   struct tm tmv;
   localtime_r(&t, &tmv);
   strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tmv);
   return std::string(buf);
}

std::string HMS(double sec)
{
   if (sec < 0) sec = 0;
   long long s = (long long)sec;
   char buf[64];
   snprintf(buf, sizeof(buf), "%02lld:%02lld:%02lld",
            s / 3600, (s % 3600) / 60, s % 60);
   return std::string(buf);
}

std::string SqlEsc(const std::string& in)
{
   std::string out;
   for (size_t i = 0; i < in.size(); ++i) {
      if (in[i] == '\'')                      out += "''";
      else if (in[i] == '\n' || in[i] == '\r') out += ' ';
      else                                     out += in[i];
   }
   return out;
}

std::string Trim(const std::string& s)
{
   size_t a = s.find_first_not_of(" \t\r\n");
   if (a == std::string::npos) return "";
   size_t b = s.find_last_not_of(" \t\r\n");
   return s.substr(a, b - a + 1);
}

std::string AbsPath(const std::string& p)
{
   if (p.empty() || p[0] == '/') return p;
   std::string t = gSystem->WorkingDirectory();
   t += "/";
   t += p;
   return t;
}

std::string LowerOf(const std::string& s)
{
   std::string o;
   for (size_t i = 0; i < s.size(); ++i) o += (char)tolower(s[i]);
   return o;
}

// ---------------------------------------------------------------------
//  이름에서 ADC 종류를 판정한다.
//  rc.py 는 name[0].lower() 를 사용하므로 'MERGER' -> 'm' (MADC) 로
//  오인하는 버긎가 있다. 여기에서는 부분벇본 검색을 사용하여
//  FADCMERGER -> FADC, SADCMERGER -> SADC 로 정확하게 분리한다.
//  검사 순서가 중요: AMOREADC 를 AADC 보다 음직 먼지 본다.
// ---------------------------------------------------------------------
char AdcLetterOf(const std::string& name, std::string& kind)
{
   static const char* const K[] = {"FADC", "SADC", "IADC", "GADC",
                                   "AMOREADC", "AADC", "MADC", 0};
   static const char        L[] = { 'f',    's',    'i',    'g',
                                    'a',        'a',    'm' };
   for (int i = 0; K[i]; ++i) {
      if (name.find(K[i]) != std::string::npos) {
         kind = (std::strcmp(K[i], "AMOREADC") == 0) ? "AADC" : K[i];
         return L[i];
      }
   }
   kind.clear();
   return 0;
}

std::string KindOfLetter(char l)
{
   switch (tolower(l)) {
      case 'f': return "FADC";
      case 's': return "SADC";
      case 'i': return "IADC";
      case 'g': return "GADC";
      case 'm': return "MADC";
      case 'a': return "AADC";
   }
   return "";
}

} // namespace

// =========================================================== ctor/dtor
RunControl::RunControl(const Config& c)
  : fCfg(c), fTCB(0), fStatus(0), fSubRun(0), fStartTime(0), fEndTime(0),
    fRunStartWall(0), fRootFile(0), fTree(0),
    bRun(0), bSubRun(0), bNDaq(0), bState(0), bCTime(0), bDaqTime(0)
{
   for (int i = 0; i < kMaxDaq; ++i) { bNev[i] = 0; bSRate[i] = 0; bARate[i] = 0; }
}

RunControl::~RunControl()
{
   CloseMonitors();
   if (fTCB) { delete fTCB; fTCB = 0; }
   if (fRootFile) {
      fRootFile->cd();
      if (fTree) fTree->Write();
      fRootFile->Close();
      delete fRootFile;
      fRootFile = 0;
   }
   if (fLog.is_open()) fLog.close();
}

void RunControl::Log(const std::string& s)
{
   std::string line = TimeStr(time(0)) + " " + s;
   if (fLog.is_open()) fLog << line << std::endl;
   if (fCfg.quiet)     std::cout << line << std::endl;
}

// ================================================================= Init
bool RunControl::Init()
{
   if (fCfg.configFile.empty()) {
      std::cerr << "[FATAL] --config <hardware config file> is required" << std::endl;
      return false;
   }
   fCfg.configFile = AbsPath(fCfg.configFile);
   if (gSystem->AccessPathName(fCfg.configFile.c_str(), kReadPermission)) {
      std::cerr << "[FATAL] cannot read config file : " << fCfg.configFile << std::endl;
      return false;
   }
   if (fCfg.shift.empty()) {
      std::cerr << "[FATAL] --shift <crew name> is required" << std::endl;
      return false;
   }
   if (fCfg.runtype.empty()) {
      std::cerr << "[FATAL] --runtype is empty" << std::endl;
      return false;
   }
   if (fCfg.splitTimeMin <= 0) {
      std::cerr << "[FATAL] --split-time must be > 0 [min]" << std::endl;
      return false;
   }
   if (fCfg.runLengthHour <= 0) {
      std::cerr << "[FATAL] --run-length must be > 0 [hour]" << std::endl;
      return false;
   }
   if (fCfg.runLengthHour * 3600.0 < fCfg.splitTimeMin * 60.0) {
      std::cerr << "[FATAL] run length is shorter than split time" << std::endl;
      return false;
   }
   if (fCfg.onldaqDir.empty() || fCfg.rawdataDir.empty()) {
      std::cerr << "[FATAL] --onldaqdir / --rawdatadir required" << std::endl;
      return false;
   }
   if (fCfg.binDir.empty()) fCfg.binDir = fCfg.onldaqDir + "/bin";

   // executedaq.sh 는 install/bin 직하에 있어야 하고 실행 가능해야 한다
   const std::string exe = fCfg.binDir + "/" + fCfg.exeScript;
   if (gSystem->AccessPathName(exe.c_str(), kExecutePermission)) {
      std::cerr << "[FATAL] not found or not executable : " << exe << "\n"
                << "        check --onldaqdir / --bindir" << std::endl;
      return false;
   }

   if (!ParseConfigFile()) return false;
   if (!ResolveKinds())    return false;

   // executedaq.sh 가 로그를 리다이렉트하는 디렉토리는 미리 있어야 한다.
   // 없으니 DAQ 프로세스가 조용히 죽는다.
   if (!fCfg.dryRun) {
      gSystem->mkdir((fCfg.rawdataDir + "/LOG").c_str(),    kTRUE);
      gSystem->mkdir((fCfg.rawdataDir + "/CONFIG").c_str(), kTRUE);
   }

   if (fCfg.useDB) {
      if (gSystem->AccessPathName(fCfg.dbFile.c_str(), kReadPermission)) {
         std::cerr << "[FATAL] no run catalog DB : " << fCfg.dbFile << "\n"
                   << "        create it with DAQRC/create_runcatalog_db.py,\n"
                   << "        or run with --no-db --run <N>" << std::endl;
         return false;
      }
      if (Trim(gSystem->GetFromPipe("which sqlite3 2>/dev/null").Data()).empty()) {
         std::cerr << "[FATAL] 'sqlite3' not found.  sudo dnf install -y sqlite\n"
                   << "        (or run with --no-db --run <N>)" << std::endl;
         return false;
      }
      if (!LoadDBColumns()) return false;
   } else if (fCfg.startRun <= 0) {
      std::cerr << "[FATAL] --no-db requires --run <start run number>" << std::endl;
      return false;
   }

   if (!fCfg.logFile.empty()) {
      fLog.open(fCfg.logFile.c_str(), std::ios::app);
      if (!fLog.is_open())
         std::cerr << "[WARN] cannot open log file : " << fCfg.logFile << std::endl;
   }
   if (!fCfg.rootFile.empty() && !fCfg.dryRun) {
      fRootFile = TFile::Open(fCfg.rootFile.c_str(), "RECREATE");
      if (!fRootFile || fRootFile->IsZombie()) {
         std::cerr << "[WARN] cannot create ROOT file : " << fCfg.rootFile << std::endl;
         fRootFile = 0;
      } else {
         fRootFile->cd();
         fTree = new TTree("daqmon", "RENE DAQ online monitor");
         fTree->Branch("ctime",   &bCTime,   "ctime/D");
         fTree->Branch("run",     &bRun,     "run/I");
         fTree->Branch("subrun",  &bSubRun,  "subrun/I");
         fTree->Branch("state",   &bState,   "state/I");
         fTree->Branch("daqtime", &bDaqTime, "daqtime/D");
         fTree->Branch("ndaq",    &bNDaq,    "ndaq/I");
         fTree->Branch("nev",     bNev,      "nev[ndaq]/L");
         fTree->Branch("srate",   bSRate,    "srate[ndaq]/D");
         fTree->Branch("arate",   bARate,    "arate[ndaq]/D");
      }
   }

   char buf[1024];
   std::cout << "======================================================\n"
             << " RENE / CUPDAQ  Text-mode Run Control  (ROOT / C++)\n"
             << "======================================================\n"
             << " shift       : " << fCfg.shift      << "\n"
             << " run type    : " << fCfg.runtype    << "\n"
             << " run desc    : " << fCfg.rundesc    << "\n"
             << " config      : " << fCfg.configFile << "\n";
   snprintf(buf, sizeof(buf), " split time  : %d [min] = %d [s]   (TCB -p : %s)\n",
            fCfg.splitTimeMin, fCfg.splitTimeMin * 60,
            fCfg.tcbSplit ? "enabled" : "DISABLED");
   std::cout << buf;
   snprintf(buf, sizeof(buf), " run length  : %.4f [hour]    max runs : %s\n",
            fCfg.runLengthHour,
            fCfg.maxRuns ? std::to_string(fCfg.maxRuns).c_str() : "unlimited");
   std::cout << buf;
   std::cout << " DAQ server  : " << fCfg.daqServerIP << ":" << fCfg.daqServerPort << "\n"
             << " onldaq dir  : " << fCfg.onldaqDir  << "\n"
             << " rawdata dir : " << fCfg.rawdataDir << "\n"
             << " exe script  : " << exe << "\n"
             << " run catalog : " << (fCfg.useDB ? fCfg.dbFile : std::string("(disabled)")) << "\n"
             << " heartbeat   : " << (fCfg.heartbeatFile.empty() ? std::string("(none)")
                                                                 : fCfg.heartbeatFile) << "\n"
             << " dry run     : " << (fCfg.dryRun ? "YES" : "no") << "\n"
             << "------------------------------------------------------\n"
             << " DAQ nodes (boot order):\n";
   for (size_t i = 0; i < fNodes.size(); ++i) {
      const DaqNode& n = fNodes[i];
      const char* m = (n.mode == onl::kMODE_TCB) ? "TCB"
                    : (n.mode == onl::kMODE_MERGER ? "MERGER" : "ADC");
      char flag[16] = "";
      if (n.letter) snprintf(flag, sizeof(flag), "-%c", n.letter);
      snprintf(buf, sizeof(buf), "   %d) %-6s daqid=%-3d %-12s %s:%-6d %-3s %s\n",
               (int)i + 1, m, n.dnum, n.name.c_str(), n.ip.c_str(), n.port,
               flag, n.dosend ? "-x" : "");
      std::cout << buf;
      if (n.mode != onl::kMODE_TCB && n.port == 22)
         std::cout << "      [WARN] port 22 is the SSH port. is this really the DAQ port?\n";
   }
   std::cout << "======================================================" << std::endl;
   return true;
}

// ==================================================== config 파일 파싱
bool RunControl::ParseConfigFile()
{
   fNodes.clear();
   std::ifstream fp(fCfg.configFile.c_str());
   if (!fp.is_open()) return false;

   std::string line;
   while (std::getline(fp, line)) {
      line = Trim(line);
      if (line.find("SERVER") == std::string::npos) continue;
      if (line.find('#') != std::string::npos) continue;   // rc.py 와 동일 정책

      std::istringstream ss(line);
      std::string tok, f1, f2, f3, f4;
      if (!(ss >> tok >> f1 >> f2 >> f3 >> f4)) continue;
      if (tok != "SERVER") continue;

      DaqNode nd;
      nd.dnum = atoi(f1.c_str());
      nd.name = f2;
      nd.ip   = f3;
      nd.port = atoi(f4.c_str());
      if      (nd.name.find("TCB")    != std::string::npos) nd.mode = onl::kMODE_TCB;
      else if (nd.name.find("MERGER") != std::string::npos) nd.mode = onl::kMODE_MERGER;
      else                                                  nd.mode = onl::kMODE_ADC;
      fNodes.push_back(nd);
   }
   fp.close();

   if (fNodes.empty()) {
      std::cerr << "[FATAL] no SERVER line in " << fCfg.configFile << "\n"
                << "        note: any line containing '#' is skipped (same as rc.py)"
                << std::endl;
      return false;
   }

   int ntcb = 0;
   for (size_t i = 0; i < fNodes.size(); ++i)
      if (fNodes[i].mode == onl::kMODE_TCB) ++ntcb;
   if (ntcb != 1) {
      std::cerr << "[FATAL] exactly one TCB expected, found " << ntcb << std::endl;
      return false;
   }
   if (fNodes.size() > (size_t)kMaxDaq + 1) {
      std::cerr << "[FATAL] too many DAQ nodes (max " << (int)kMaxDaq << " + TCB)" << std::endl;
      return false;
   }

   // 중복 포트 검사 (같은 IP:PORT 를 둘이 쓰면 모니토가 섞인다)
   for (size_t i = 0; i < fNodes.size(); ++i)
      for (size_t j = i + 1; j < fNodes.size(); ++j)
         if (fNodes[i].ip == fNodes[j].ip && fNodes[i].port == fNodes[j].port) {
            std::cerr << "[FATAL] duplicated endpoint " << fNodes[i].ip << ":"
                      << fNodes[i].port << " used by '" << fNodes[i].name
                      << "' and '" << fNodes[j].name << "'" << std::endl;
            return false;
         }

   // 부톥 순서 : MERGER -> ADC -> TCB
   //  merger/TCB 가 서버 역할이므로 TCB 가 마지막이어야 접속이 성립한다.
   //  rc.py 는 dopt 문자열로 정렬하여 AADC 가 있을 때 TCB 가 마지막이 되지
   //  않는 버긎가 있다. 여기서는 mode 로 명시적으로 강제한다.
   std::vector<DaqNode> ordered;
   const int order[3] = {onl::kMODE_MERGER, onl::kMODE_ADC, onl::kMODE_TCB};
   for (int p = 0; p < 3; ++p) {
      std::vector<DaqNode> grp;
      for (size_t i = 0; i < fNodes.size(); ++i)
         if (fNodes[i].mode == order[p]) grp.push_back(fNodes[i]);
      std::stable_sort(grp.begin(), grp.end(),
                       [](const DaqNode& a, const DaqNode& b) {
                          if (a.name != b.name) return a.name < b.name;
                          return a.dnum < b.dnum;
                       });
      ordered.insert(ordered.end(), grp.begin(), grp.end());
   }
   fNodes = ordered;
   return true;
}

// ---------------------------------------------------------------------
//  ADC 종류(-f/-s/...) 와 -x 플래그 통합 해석.
//  FADCMERGER / SADCMERGER 가 동시에 있는 구성을 지원하며,
//  같은 종류의 merger 가 둘 이상이면 에러로 멈춘다.
// ---------------------------------------------------------------------
bool RunControl::ResolveKinds()
{
   std::vector<std::string> adcKinds;

   // 1) 이름으로 종류 판정
   for (size_t i = 0; i < fNodes.size(); ++i) {
      DaqNode& n = fNodes[i];
      if (n.mode == onl::kMODE_TCB) { n.letter = 0; n.kind = "TCB"; continue; }
      n.letter = AdcLetterOf(n.name, n.kind);
      if (n.mode == onl::kMODE_ADC) {
         if (!n.letter) {
            std::cerr << "[FATAL] cannot determine ADC type from name '" << n.name << "'\n"
                      << "        the name must contain one of\n"
                      << "        FADC / SADC / IADC / GADC / MADC / AMOREADC" << std::endl;
            return false;
         }
         if (std::find(adcKinds.begin(), adcKinds.end(), n.kind) == adcKinds.end())
            adcKinds.push_back(n.kind);
      }
   }

   // 2) MERGER 종류 확정
   for (size_t i = 0; i < fNodes.size(); ++i) {
      DaqNode& n = fNodes[i];
      if (n.mode != onl::kMODE_MERGER) continue;

      if (n.letter) {
         // FADCMERGER / SADCMERGER 처럼 이름에 종류가 들어 있는 정상 상황
         continue;
      }
      if (fCfg.mergerType) {
         n.letter = (char)tolower(fCfg.mergerType);
         n.kind   = KindOfLetter(n.letter);
         if (n.kind.empty()) {
            std::cerr << "[FATAL] bad --merger-type '" << fCfg.mergerType
                      << "' (use f|s|i|g|m|a)" << std::endl;
            return false;
         }
         std::cout << "[INFO] merger '" << n.name << "' type forced to "
                   << n.kind << " by --merger-type" << std::endl;
      } else if (adcKinds.size() == 1) {
         n.kind = adcKinds[0];
         std::string dummy;
         n.letter = AdcLetterOf(n.kind, dummy);
         std::cout << "[INFO] merger '" << n.name << "' type inferred as " << n.kind
                   << " (the only ADC kind in this config)" << std::endl;
      } else {
         std::cerr << "[FATAL] merger '" << n.name << "' has no ADC kind in its name,\n"
                   << "        and this config has " << adcKinds.size()
                   << " ADC kinds (";
         for (size_t k = 0; k < adcKinds.size(); ++k)
            std::cerr << (k ? ", " : "") << adcKinds[k];
         std::cerr << ").\n"
                   << "        rename it to FADCMERGER / SADCMERGER, or pass\n"
                   << "        --merger-type f|s|i|g|m" << std::endl;
         return false;
      }
   }

   // 3) 같은 종류의 merger 중복 금지 + 고아 merger 경고
   for (size_t i = 0; i < fNodes.size(); ++i) {
      if (fNodes[i].mode != onl::kMODE_MERGER) continue;
      for (size_t j = i + 1; j < fNodes.size(); ++j) {
         if (fNodes[j].mode != onl::kMODE_MERGER) continue;
         if (fNodes[i].kind == fNodes[j].kind) {
            std::cerr << "[FATAL] two mergers of the same kind (" << fNodes[i].kind
                      << ") : '" << fNodes[i].name << "' and '" << fNodes[j].name
                      << "'" << std::endl;
            return false;
         }
      }
      bool found = false;
      for (size_t j = 0; j < fNodes.size(); ++j)
         if (fNodes[j].mode == onl::kMODE_ADC && fNodes[j].kind == fNodes[i].kind) {
            found = true;
            break;
         }
      if (!found)
         std::cout << "[WARN] merger '" << fNodes[i].name << "' (" << fNodes[i].kind
                   << ") has no matching ADC in this config" << std::endl;
   }

   // 4) -x : 같은 종류의 merger 가 있으면 ADC 가 merger 로 전송한다
   for (size_t i = 0; i < fNodes.size(); ++i) {
      DaqNode& n = fNodes[i];
      if (n.mode != onl::kMODE_ADC) continue;
      for (size_t j = 0; j < fNodes.size(); ++j)
         if (fNodes[j].mode == onl::kMODE_MERGER && fNodes[j].kind == n.kind) {
            n.dosend = true;
            break;
         }
   }
   return true;
}

// =================================================================== DB
TString RunControl::RunSQL(const std::string& sql)
{
   char tmp[512];
   snprintf(tmp, sizeof(tmp), "%s/rcterm_%d.sql",
            gSystem->TempDirectory(), gSystem->GetPid());
   std::ofstream ofs(tmp);
   if (!ofs.is_open()) return TString("");
   ofs << sql << std::endl;
   ofs.close();

   TString cmd = "sqlite3 '";
   cmd += fCfg.dbFile.c_str();
   cmd += "' < '";
   cmd += tmp;
   cmd += "' 2>&1";
   TString out = gSystem->GetFromPipe(cmd);
   gSystem->Unlink(tmp);
   return out;
}

bool RunControl::LoadDBColumns()
{
   fDBColumns.clear();
   TString out = RunSQL("PRAGMA table_info(runcatalog);");
   std::istringstream ss(out.Data());
   std::string line;
   while (std::getline(ss, line)) {
      size_t p1 = line.find('|');
      if (p1 == std::string::npos) continue;
      size_t p2 = line.find('|', p1 + 1);
      if (p2 == std::string::npos) continue;
      fDBColumns.push_back(line.substr(p1 + 1, p2 - p1 - 1));
   }
   if (fDBColumns.empty()) {
      std::cerr << "[FATAL] table 'runcatalog' not found in " << fCfg.dbFile << "\n"
                << "        sqlite3 said: " << out << std::endl;
      return false;
   }
   if (!HasColumn("runnum")) {
      std::cerr << "[FATAL] column 'runnum' missing; schema is not compatible" << std::endl;
      return false;
   }
   std::cout << " DB columns  : ";
   for (size_t i = 0; i < fDBColumns.size(); ++i) std::cout << fDBColumns[i] << " ";
   std::cout << std::endl;
   return true;
}

bool RunControl::HasColumn(const std::string& c) const
{
   return std::find(fDBColumns.begin(), fDBColumns.end(), c) != fDBColumns.end();
}

int RunControl::NextRunNumberFromDB()
{
   // pydblite 의 table.insert() + commit() 과 동일 효과.
   // runnum 은 INTEGER PRIMARY KEY (rowid alias) 이므로
   // last_insert_rowid() 가 그대로 run number 가 된다.
   char sp[64];
   snprintf(sp, sizeof(sp), ", Split T [m] = %d", fCfg.splitTimeMin);
   const std::string desc = fCfg.rundesc + sp;

   std::vector<std::string> cols, vals;
   if (HasColumn("shift"))   { cols.push_back("shift");   vals.push_back("'" + SqlEsc(fCfg.shift) + "'"); }
   if (HasColumn("runtype")) { cols.push_back("runtype"); vals.push_back("'" + SqlEsc(fCfg.runtype) + "'"); }
   if (HasColumn("rundesc")) { cols.push_back("rundesc"); vals.push_back("'" + SqlEsc(desc) + "'"); }
   if (HasColumn("config"))  { cols.push_back("config");  vals.push_back("'" + SqlEsc(fCfg.configFile) + "'"); }

   std::ostringstream sql;
   sql << "BEGIN IMMEDIATE;\nINSERT INTO runcatalog ";
   if (cols.empty()) {
      sql << "DEFAULT VALUES;\n";
   } else {
      sql << "(";
      for (size_t i = 0; i < cols.size(); ++i) { if (i) sql << ","; sql << cols[i]; }
      sql << ") VALUES (";
      for (size_t i = 0; i < vals.size(); ++i) { if (i) sql << ","; sql << vals[i]; }
      sql << ");\n";
   }
   sql << "SELECT last_insert_rowid();\nCOMMIT;\n";

   if (fCfg.dryRun) {
      std::cout << "[DRY] SQL >>>\n" << sql.str() << "[DRY] SQL <<<" << std::endl;
      return (fCfg.startRun > 0) ? fCfg.startRun : 999999;
   }

   TString out = RunSQL(sql.str());
   std::istringstream ss(out.Data());
   std::string line, last;
   while (std::getline(ss, line)) { line = Trim(line); if (!line.empty()) last = line; }
   const int run = atoi(last.c_str());
   if (run <= 0) {
      std::cerr << "[FATAL] cannot get run number from DB.\n"
                << "        sqlite3 said: " << out << std::endl;
      return -1;
   }
   return run;
}

void RunControl::FinalizeRunInDB(int run)
{
   if (!fCfg.useDB || fCfg.dryRun) return;

   std::ostringstream sql;
   sql << "UPDATE runcatalog SET ";
   bool first = true;
   if (HasColumn("stime")) {
      sql << "stime='" << SqlEsc(TimeStr((time_t)fStartTime)) << "'";
      first = false;
   }
   if (HasColumn("etime")) {
      if (!first) sql << ",";
      sql << "etime='" << SqlEsc(TimeStr((time_t)fEndTime)) << "'";
      first = false;
   }
   if (HasColumn("onlbit")) {
      if (!first) sql << ",";
      sql << "onlbit=" << (fCfg.goodRun ? 1 : 0);
      first = false;
   }
   if (first) return;
   sql << " WHERE runnum=" << run << ";\n";

   // DAQ 종류별 이벤트 수 / 시간 : 해당 컬럼이 있을 때만
   for (size_t i = 0; i < fMonNames.size(); ++i) {
      const std::string& k = fMonKinds[i];
      if (k.size() != 4) continue;                 // FADC / SADC / ...
      const std::string lo = LowerOf(k);           // fadc / sadc
      const TrgStat& st = fStats[fMonNames[i]];
      if (HasColumn("n" + lo))
         sql << "UPDATE runcatalog SET n" << lo << "=" << (long long)st.n
             << " WHERE runnum=" << run << ";\n";
      if (HasColumn("t" + lo))
         sql << "UPDATE runcatalog SET t" << lo << "=" << st.t
             << " WHERE runnum=" << run << ";\n";
   }

   const std::string o = Trim(RunSQL(sql.str()).Data());
   if (!o.empty()) std::cerr << "[WARN] sqlite3: " << o << std::endl;
}

// ================================================================= boot
bool RunControl::BootRun(int run)
{
   fStartTime = 0;
   fEndTime   = 0;
   fSubRun    = 0;
   fStatus    = 0;
   fStats.clear();

   char rc[512];
   snprintf(rc, sizeof(rc), "%s/CONFIG/%06d.config", fCfg.rawdataDir.c_str(), run);
   fRunConfig = rc;

   // 1) config 사본 (단일 PC 이므로 cp)
   TString cp = "cp -f '";
   cp += fCfg.configFile.c_str();
   cp += "' '";
   cp += fRunConfig.c_str();
   cp += "'";
   if (fCfg.dryRun) {
      std::cout << "[DRY] " << cp << std::endl;
   } else if (gSystem->Exec(cp) != 0) {
      std::cerr << "[ERROR] failed to copy config to " << fRunConfig << std::endl;
      return false;
   }

   const int splitSec = fCfg.splitTimeMin * 60;      // TCB -p 는 [초]

   // 2) MERGER -> ADC -> TCB
   for (size_t i = 0; i < fNodes.size(); ++i) {
      const DaqNode& n = fNodes[i];
      char sopt[1024], dopt[1024];

      if (n.mode == onl::kMODE_TCB) {
         snprintf(sopt, sizeof(sopt), "-t -r %d -n %s", run, n.name.c_str());
         if (fCfg.tcbSplit)
            snprintf(dopt, sizeof(dopt), "-d %d -r %d -c %s -p %d",
                     n.dnum, run, fRunConfig.c_str(), splitSec);
         else
            snprintf(dopt, sizeof(dopt), "-d %d -r %d -c %s",
                     n.dnum, run, fRunConfig.c_str());
      } else {
         snprintf(sopt, sizeof(sopt), "%s -r %d -n %s",
                  (n.mode == onl::kMODE_MERGER ? "-m" : "-d"), run, n.name.c_str());
         snprintf(dopt, sizeof(dopt), "-%c -d %d -c %s -r %d%s",
                  n.letter, n.dnum, fRunConfig.c_str(), run,
                  (n.mode == onl::kMODE_ADC && n.dosend) ? " -x" : "");
      }

      TString cmd;
      cmd.Form("%s/%s %s --onldaqdir=%s --rawdatadir=%s -o \"%s\"",
               fCfg.binDir.c_str(), fCfg.exeScript.c_str(), sopt,
               fCfg.onldaqDir.c_str(), fCfg.rawdataDir.c_str(), dopt);

      if (n.mode == onl::kMODE_TCB) gSystem->Sleep(1000);   // rc.py 와 동일
      if (fCfg.dryRun) {
         std::cout << "[DRY] " << cmd << std::endl;
      } else {
         Log(std::string("EXEC ") + cmd.Data());
         gSystem->Exec(cmd);
      }
      if (n.mode == onl::kMODE_MERGER) gSystem->Sleep(500);
   }
   gSystem->Sleep(1000);
   return true;
}

bool RunControl::OpenTCB()
{
   if (fTCB) { delete fTCB; fTCB = 0; }
   fTCB = new OnlSocket(fCfg.daqServerIP, fCfg.daqServerPort);

   double waited = 0;
   while (waited < fCfg.bootTimeout) {
      if (fgStop) return false;
      if (fTCB->Connect(3)) return true;
      gSystem->Sleep(500);
      waited += 0.5;
   }
   std::cerr << "[ERROR] cannot connect to TCB " << fCfg.daqServerIP << ":"
             << fCfg.daqServerPort << "\n"
             << "        check " << fCfg.rawdataDir << "/LOG/TCB_*.log" << std::endl;
   return false;
}

bool RunControl::SetupMonitors()
{
   CloseMonitors();
   for (size_t i = 0; i < fNodes.size(); ++i) {
      const DaqNode& n = fNodes[i];
      if (n.mode == onl::kMODE_TCB) continue;          // rc.py 와 동일

      OnlSocket* s = new OnlSocket(n.ip, n.port);
      if (!s->Connect(3)) { delete s; continue; }
      OnlMessage m;
      if (!s->Query(onl::kQUERYMONITOR, m) || m.m1 == 0) { delete s; continue; }

      fMonNames.push_back(n.name);
      fMonKinds.push_back(n.kind);
      fMonSocks.push_back(s);
      fStats[n.name] = TrgStat();
   }
   bNDaq = (int)fMonNames.size();
   if (bNDaq == 0) std::cerr << "[WARN] no monitorable DAQ responded" << std::endl;
   return true;
}

void RunControl::CloseMonitors()
{
   for (size_t i = 0; i < fMonSocks.size(); ++i) delete fMonSocks[i];
   fMonSocks.clear();
   fMonNames.clear();
   fMonKinds.clear();
   bNDaq = 0;
}

// ============================================================ state m/c
bool RunControl::SendCmd(unsigned long long cmd, const char* what)
{
   if (fCfg.dryRun) { std::cout << "[DRY] send " << what << std::endl; return true; }
   if (!fTCB || !fTCB->IsOpen()) {
      std::cerr << "[ERROR] TCB socket closed; cannot send " << what << std::endl;
      return false;
   }
   if (!fTCB->Send(cmd)) {
      std::cerr << "[ERROR] failed to send " << what << std::endl;
      return false;
   }
   Log(std::string("CMD ") + what);
   return true;
}

unsigned long long RunControl::QueryStatus()
{
   if (fCfg.dryRun || !fTCB || !fTCB->IsOpen()) return 0;
   OnlMessage m;
   if (!fTCB->Query(onl::kQUERYDAQSTATUS, m)) return 0;
   return m.m1;
}

bool RunControl::WaitState(int state, double timeoutSec)
{
   if (fCfg.dryRun) return true;
   double waited = 0;
   while (waited < timeoutSec) {
      if (fgStop) return false;
      fStatus = QueryStatus();
      if (CheckError(fStatus)) {
         std::cerr << "[ERROR] DAQ reported ERROR (status=0x" << std::hex << fStatus
                   << std::dec << ")" << std::endl;
         return false;
      }
      if (CheckState(fStatus, state)) return true;
      gSystem->Sleep(100);
      waited += 0.1;
   }
   std::cerr << "[ERROR] timeout waiting for " << onl::StateName(state)
             << " (status=0x" << std::hex << fStatus << std::dec << ")" << std::endl;
   return false;
}

void RunControl::QueryRunInfo()
{
   if (fCfg.dryRun) return;
   OnlMessage m;
   if (!fTCB || !fTCB->Query(onl::kQUERYRUNINFO, m)) return;
   fSubRun = m.m2;
   if (m.m3 > 0) fStartTime = m.m3;
   if (m.m4 > 0) fEndTime   = m.m4;
}

void RunControl::UpdateStats(bool finalRead)
{
   if (fCfg.dryRun) return;
   for (size_t i = 0; i < fMonSocks.size(); ++i) {
      if (!fMonSocks[i]->IsOpen()) continue;
      OnlMessage m;
      if (!fMonSocks[i]->Query(onl::kQUERYTRGINFO, m)) continue;

      TrgStat& st = fStats[fMonNames[i]];
      const unsigned long long n = m.m1;
      const double t  = (double)m.m2 / 1.0e9;        // ns -> s
      const double dt = t - st.pt;
      const double dn = (double)n - (double)st.pn;
      st.n = n;
      st.t = t;
      if (t  > 0) st.ar = (double)n / t;
      if (dt > 0) st.sr = dn / dt;
      if (!finalRead) { st.pt = t; st.pn = n; }
   }
}

unsigned long long RunControl::TotalEvents() const
{
   unsigned long long tot = 0;
   for (size_t i = 0; i < fMonNames.size(); ++i) {
      std::map<std::string, TrgStat>::const_iterator it = fStats.find(fMonNames[i]);
      if (it != fStats.end()) tot += it->second.n;
   }
   return tot;
}

// =============================================================== output
void RunControl::PrintScreen(int run, int cycle, double remain)
{
   const int    st   = CheckError(fStatus) ? onl::kERROR : GetState(fStatus);
   const double daqt = fMonNames.empty() ? 0 : fStats[fMonNames[0]].t;
   char buf[512];

   std::cout << "\033[H\033[2J";
   std::cout << "======================================================================\n";
   snprintf(buf, sizeof(buf),
            "  RENE / CUPDAQ  Run Control (text mode, ROOT C++)       cycle #%d\n", cycle);
   std::cout << buf;
   std::cout << "======================================================================\n";
   std::cout << "        Current Time : " << TimeStr(time(0)) << "\n\n";
   snprintf(buf, sizeof(buf), "          Run Number : %06d / %llu\n",
            run, (unsigned long long)fSubRun);
   std::cout << buf;
   snprintf(buf, sizeof(buf), "          Split Time : %d [min]\n", fCfg.splitTimeMin);
   std::cout << buf;
   std::cout << "           DAQ State : " << onl::StateName(st) << "\n"
             << "          Start Time : " << TimeStr((time_t)fStartTime) << "\n"
             << "            End Time : " << TimeStr((time_t)fEndTime) << "\n"
             << "            DAQ Time : " << HMS(daqt) << "\n"
             << "         Run Elapsed : " << HMS((double)(time(0) - fRunStartWall))
             << "   /   Remaining : " << HMS(remain) << "\n";
   snprintf(buf, sizeof(buf), "        Run Rotation : every %.4f [hour]   (%s)\n",
            fCfg.runLengthHour,
            fCfg.maxRuns ? ("max " + std::to_string(fCfg.maxRuns) + " runs").c_str()
                         : "unlimited");
   std::cout << buf;
   std::cout << "\n  ------------------------------------------------------------------\n"
             << "        DAQ          Events       Rate[Hz]     Average[Hz]\n"
             << "  ------------------------------------------------------------------\n";
   for (size_t i = 0; i < fMonNames.size(); ++i) {
      const TrgStat& s = fStats[fMonNames[i]];
      snprintf(buf, sizeof(buf), "  %12s  %13lld  %12.1f  %14.1f\n",
               fMonNames[i].c_str(), (long long)s.n, s.sr, s.ar);
      std::cout << buf;
   }
   std::cout << "  ------------------------------------------------------------------\n"
             << "  Ctrl-C : end the current run gracefully and exit\n" << std::flush;
}

void RunControl::PrintLine(int run, int cycle)
{
   const int st = CheckError(fStatus) ? onl::kERROR : GetState(fStatus);
   char buf[256];
   std::ostringstream ss;
   snprintf(buf, sizeof(buf), "cycle=%d run=%06d sub=%llu state=%s",
            cycle, run, (unsigned long long)fSubRun, onl::StateName(st));
   ss << buf;
   if (!fMonNames.empty()) ss << " daqtime=" << HMS(fStats[fMonNames[0]].t);
   for (size_t i = 0; i < fMonNames.size(); ++i) {
      const TrgStat& s = fStats[fMonNames[i]];
      snprintf(buf, sizeof(buf), " | %s n=%lld sr=%.1f ar=%.1f",
               fMonNames[i].c_str(), (long long)s.n, s.sr, s.ar);
      ss << buf;
   }
   const std::string line = TimeStr(time(0)) + " " + ss.str();
   std::cout << line << std::endl;
   if (fLog.is_open()) fLog << line << std::endl;
}

// ---------------------------------------------------------------------
//  외부 감시자(rcsupervisor)가 읽는 상태 파일.
//  tmp 에 쓴 뒤 rename \u2192 부분적으로 읽힐 일이 없도록 한다.
// ---------------------------------------------------------------------
void RunControl::WriteHeartbeat(int run, const char* phase)
{
   if (fCfg.heartbeatFile.empty()) return;

   const std::string tmp = fCfg.heartbeatFile + ".tmp";
   std::ofstream o(tmp.c_str(), std::ios::trunc);
   if (!o.is_open()) return;

   const int    st   = CheckError(fStatus) ? onl::kERROR : GetState(fStatus);
   const double daqt = fMonNames.empty() ? 0 : fStats[fMonNames[0]].t;

   o << "time="     << (long long)time(0) << "\n"
     << "pid="      << gSystem->GetPid()  << "\n"
     << "phase="    << phase              << "\n"
     << "run="      << run                << "\n"
     << "subrun="   << (unsigned long long)fSubRun << "\n"
     << "state="    << onl::StateName(st) << "\n"
     << "statebit=" << st                 << "\n"
     << "error="    << (CheckError(fStatus) ? 1 : 0) << "\n"
     << "status="   << (unsigned long long)fStatus << "\n"
     << "daqtime="  << daqt               << "\n"
     << "totev="    << (unsigned long long)TotalEvents() << "\n"
     << "ndaq="     << fMonNames.size()   << "\n";
   for (size_t i = 0; i < fMonNames.size(); ++i) {
      const TrgStat& s = fStats[fMonNames[i]];
      o << "daq" << i << "=" << fMonNames[i]
        << " n="  << (long long)s.n
        << " sr=" << s.sr
        << " ar=" << s.ar << "\n";
   }
   o.close();
   ::rename(tmp.c_str(), fCfg.heartbeatFile.c_str());
}

void RunControl::FillTree(int run)
{
   if (!fTree) return;
   bCTime   = (double)time(0);
   bRun     = run;
   bSubRun  = (int)fSubRun;
   bState   = CheckError(fStatus) ? onl::kERROR : GetState(fStatus);
   bDaqTime = fMonNames.empty() ? 0 : fStats[fMonNames[0]].t;
   bNDaq    = (int)fMonNames.size();
   if (bNDaq > kMaxDaq) bNDaq = kMaxDaq;
   for (int i = 0; i < bNDaq; ++i) {
      const TrgStat& s = fStats[fMonNames[i]];
      bNev[i]   = (long long)s.n;
      bSRate[i] = s.sr;
      bARate[i] = s.ar;
   }
   fTree->Fill();
}

// ============================================================ run cycle
bool RunControl::RunOneCycle(int run, int cycle)
{
   char buf[256];
   snprintf(buf, sizeof(buf), "[INFO] ===== cycle %d : booting run %06d =====", cycle, run);
   std::cout << "\n" << buf << std::endl;
   Log(buf);

   if (!BootRun(run)) return false;
   if (fCfg.dryRun) {
      std::cout << "[DRY] would CONFIG -> START -> monitor "
                << fCfg.runLengthHour << " h -> END -> EXIT" << std::endl;
      return true;
   }

   WriteHeartbeat(run, "booting");
   if (!OpenTCB()) return false;
   if (!WaitState(onl::kBOOTED, fCfg.bootTimeout)) return false;
   std::cout << "[INFO] booted" << std::endl;

   SetupMonitors();
   WriteHeartbeat(run, "booted");

   if (!SendCmd(onl::kCONFIGRUN, "CONFIGRUN")) return false;
   if (!WaitState(onl::kCONFIGURED, fCfg.stateTimeout)) return false;
   std::cout << "[INFO] configured" << std::endl;
   WriteHeartbeat(run, "configured");

   if (!SendCmd(onl::kSTARTRUN, "STARTRUN")) return false;
   if (!WaitState(onl::kRUNNING, fCfg.stateTimeout)) return false;
   fRunStartWall = time(0);
   snprintf(buf, sizeof(buf), "STARTED run=%06d", run);
   Log(buf);
   std::cout << "[INFO] started" << std::endl;

   // ------------------- 모니타 루프 -------------------
   const double runLenSec = fCfg.runLengthHour * 3600.0;
   bool timeUp = false;

   while (true) {
      if (fgStop) { std::cout << "\n[INFO] stop requested" << std::endl; break; }

      fStatus = QueryStatus();
      if (CheckError(fStatus)) {
         snprintf(buf, sizeof(buf), "ERROR run=%06d status=0x%llx",
                  run, (unsigned long long)fStatus);
         std::cerr << "\n[ERROR] " << buf << std::endl;
         Log(buf);
         WriteHeartbeat(run, "error");
         break;
      }
      if (!CheckState(fStatus, onl::kRUNNING)) {
         std::cerr << "\n[WARN] no longer RUNNING" << std::endl;
         WriteHeartbeat(run, "notrunning");
         break;
      }

      QueryRunInfo();
      UpdateStats(false);
      FillTree(run);
      WriteHeartbeat(run, "running");

      const double remain = runLenSec - (double)(time(0) - fRunStartWall);
      if (fCfg.quiet) PrintLine(run, cycle);
      else            PrintScreen(run, cycle, remain);

      if (remain <= 0) { timeUp = true; break; }
      gSystem->Sleep((unsigned int)(fCfg.updateSec * 1000));
   }

   // ------------------- 런 종료 -------------------
   snprintf(buf, sizeof(buf), "[INFO] ending run %06d%s ...",
            run, timeUp ? " (run length reached)" : "");
   std::cout << "\n" << buf << std::endl;
   WriteHeartbeat(run, "ending");

   bool ok = true;
   if (!SendCmd(onl::kENDRUN, "ENDRUN")) {
      ok = false;
   } else {
      gSystem->Sleep(1000);
      if (!WaitState(onl::kRUNENDED, fCfg.stateTimeout)) ok = false;
   }

   if (ok) {
      QueryRunInfo();
      UpdateStats(true);
      std::cout << "[INFO] ended  (" << TimeStr((time_t)fStartTime) << " -> "
                << TimeStr((time_t)fEndTime) << ")" << std::endl;
      for (size_t i = 0; i < fMonNames.size(); ++i) {
         const TrgStat& s = fStats[fMonNames[i]];
         snprintf(buf, sizeof(buf), "       %12s : %13lld events, %.1f s, %.1f Hz",
                  fMonNames[i].c_str(), (long long)s.n, s.t, s.ar);
         std::cout << buf << std::endl;
      }
      FinalizeRunInDB(run);
      snprintf(buf, sizeof(buf), "ENDED run=%06d", run);
      Log(buf);
   }

   WaitState(onl::kPROCENDED, 20.0);
   SendCmd(onl::kEXIT, "EXIT");
   gSystem->Sleep(1500);

   WriteHeartbeat(run, ok ? "ended" : "failed");
   CloseMonitors();
   if (fTCB) { delete fTCB; fTCB = 0; }
   return ok;
}

// ============================================================== Execute
int RunControl::Execute()
{
   int    cycle = 0, rc = 0;
   time_t prevEnd = 0;

   while (true) {
      if (fgStop) break;
      if (fCfg.maxRuns > 0 && cycle >= fCfg.maxRuns) break;

      const int run = fCfg.useDB ? NextRunNumberFromDB() : (fCfg.startRun + cycle);
      if (run <= 0) { rc = 1; break; }
      ++cycle;

      if (prevEnd > 0) {
         char b[128];
         const long gap = (long)(time(0) - prevEnd);
         snprintf(b, sizeof(b), "GAP %ld s before run=%06d", gap, run);
         std::cout << "[INFO] inter-run dead time : " << gap << " s" << std::endl;
         Log(b);
      }

      const bool ok = RunOneCycle(run, cycle);
      prevEnd = time(0);

      if (!ok) {
         std::cerr << "[FATAL] cycle " << cycle << " failed; stopping." << std::endl;
         rc = 2;
         break;
      }
      if (fCfg.dryRun) break;
   }

   if (fRootFile) {
      fRootFile->cd();
      if (fTree) fTree->Write();
      std::string s;
      for (size_t i = 0; i < fMonNames.size(); ++i) { if (i) s += ","; s += fMonNames[i]; }
      TNamed names("daqnames", s.c_str());
      names.Write();
   }
   std::cout << "[INFO] finished. total cycles = " << cycle << std::endl;
   return rc;
}
