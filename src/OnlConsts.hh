#ifndef OnlConsts_hh
#define OnlConsts_hh 1

// =====================================================================
//  RENE-daq / DAQ_cup / DAQRC / onlconsts.py 와 반드시 동일하게 유지.
//  (원본의 "Do not modify from here!!!" 영역에 대응 -> 수정 금지)
// =====================================================================
namespace onl {

const int kMESSLEN = 32;            // 8-byte unsigned x 4, little endian

// ---- commands -------------------------------------------------------
const unsigned long long kCONFIGRUN      = 1;
const unsigned long long kSTARTRUN       = 2;
const unsigned long long kENDRUN         = 3;
const unsigned long long kEXIT           = 4;
const unsigned long long kQUERYDAQSTATUS = 10;
const unsigned long long kQUERYRUNINFO   = 12;
const unsigned long long kQUERYTRGINFO   = 14;
const unsigned long long kQUERYMONITOR   = 21;

// ---- run states -----------------------------------------------------
//  주의: status 는 정수값이 아니라 비트마스크다.  (status >> state) & 1
const int kDOWN       = 0;
const int kBOOTED     = 1;
const int kCONFIGURED = 2;
const int kRUNNING    = 3;
const int kRUNENDED   = 4;
const int kPROCENDED  = 5;
const int kWARNING    = 6;
const int kERROR      = 7;

// onlconsts.py 의 kDAQSTATE. 원본 index 6 은 빈 문자열이라 Warning 으로 표기.
inline const char* StateName(int s)
{
   switch (s) {
      case 0: return "Down";
      case 1: return "Booted";
      case 2: return "Configured";
      case 3: return "Running";
      case 4: return "RunEnd";
      case 5: return "RunEnd";
      case 6: return "Warning";
      case 7: return "Error";
      default: return "Unknown";
   }
}

// ---- DAQ node mode --------------------------------------------------
const int kMODE_TCB    = 0;
const int kMODE_ADC    = 1;
const int kMODE_MERGER = 2;

} // namespace onl

// ---- site defaults (onlconsts.py 실측값, 단일 PC 구성) ----------------
#define RCTERM_DEF_SERVER_IP   "localhost"
#define RCTERM_DEF_SERVER_PORT 7809
#define RCTERM_DEF_ONLDAQ_DIR  "/home/frontend/DAQ/DAQ_cup/install"
#define RCTERM_DEF_RAWDATA_DIR "/Data"
#define RCTERM_DEF_DBFILE      "/Data/runcatalog.db"
#define RCTERM_DEF_EXESCRIPT   "executedaq.sh"

#endif
