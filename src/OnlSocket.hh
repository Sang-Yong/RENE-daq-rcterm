#ifndef OnlSocket_hh
#define OnlSocket_hh 1

// ---------------------------------------------------------------------
//  DAQRC/onlutils.py 의 소켓 헬퍼를 C++ 로 1:1 이식 (header-only).
//  메시지는 32 byte = little-endian 8-byte unsigned 4 개.
// ---------------------------------------------------------------------

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <string>

#include "OnlConsts.hh"

struct OnlMessage {
   unsigned long long m1, m2, m3, m4;
   OnlMessage() : m1(0), m2(0), m3(0), m4(0) {}
};

class OnlSocket {
public:
   OnlSocket() : fPort(0), fFD(-1) {}
   OnlSocket(const std::string& ip, int port) : fIP(ip), fPort(port), fFD(-1) {}
   ~OnlSocket() { Close(); }

   bool Connect(int timeoutSec = 5)
   {
      Close();
      fFD = ::socket(AF_INET, SOCK_STREAM, 0);
      if (fFD < 0) return false;

      int one = 1;
      ::setsockopt(fFD, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

      sockaddr_in addr;
      std::memset(&addr, 0, sizeof(addr));
      addr.sin_family = AF_INET;
      addr.sin_port   = htons((uint16_t)fPort);

      if (::inet_pton(AF_INET, fIP.c_str(), &addr.sin_addr) != 1) {
         addrinfo hints;
         std::memset(&hints, 0, sizeof(hints));
         hints.ai_family   = AF_INET;
         hints.ai_socktype = SOCK_STREAM;
         addrinfo* res = 0;
         if (::getaddrinfo(fIP.c_str(), 0, &hints, &res) != 0 || !res) {
            Close();
            return false;
         }
         addr.sin_addr = ((sockaddr_in*)res->ai_addr)->sin_addr;
         ::freeaddrinfo(res);
      }

      // 논블로킹 connect + select 로 타임아웃 처리
      int flags = ::fcntl(fFD, F_GETFL, 0);
      ::fcntl(fFD, F_SETFL, flags | O_NONBLOCK);

      if (::connect(fFD, (sockaddr*)&addr, sizeof(addr)) < 0) {
         if (errno != EINPROGRESS) { Close(); return false; }
         fd_set wset;
         FD_ZERO(&wset);
         FD_SET(fFD, &wset);
         timeval tv;
         tv.tv_sec  = timeoutSec;
         tv.tv_usec = 0;
         if (::select(fFD + 1, 0, &wset, 0, &tv) <= 0) { Close(); return false; }
         int err = 0;
         socklen_t len = sizeof(err);
         ::getsockopt(fFD, SOL_SOCKET, SO_ERROR, &err, &len);
         if (err != 0) { Close(); return false; }
      }
      ::fcntl(fFD, F_SETFL, flags);          // 블로킹 복귀

      timeval rtv;
      rtv.tv_sec  = timeoutSec;
      rtv.tv_usec = 0;
      ::setsockopt(fFD, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof(rtv));
      ::setsockopt(fFD, SOL_SOCKET, SO_SNDTIMEO, &rtv, sizeof(rtv));
      return true;
   }

   void Close() { if (fFD >= 0) { ::close(fFD); fFD = -1; } }
   bool IsOpen() const { return fFD >= 0; }

   bool Send(unsigned long long cmd)
   {
      if (fFD < 0) return false;
      unsigned char buf[onl::kMESSLEN];
      std::memset(buf, 0, sizeof(buf));
      for (int i = 0; i < 8; ++i)
         buf[i] = (unsigned char)((cmd >> (8 * i)) & 0xFF);
      size_t sent = 0;
      while (sent < sizeof(buf)) {
         ssize_t n = ::send(fFD, buf + sent, sizeof(buf) - sent, 0);
         if (n <= 0) { Close(); return false; }
         sent += (size_t)n;
      }
      return true;
   }

   bool Recv(OnlMessage& msg)
   {
      if (fFD < 0) return false;
      unsigned char buf[onl::kMESSLEN];
      size_t got = 0;
      while (got < sizeof(buf)) {
         ssize_t n = ::recv(fFD, buf + got, sizeof(buf) - got, 0);
         if (n <= 0) { Close(); return false; }
         got += (size_t)n;
      }
      msg = OnlMessage();
      for (int i = 0; i < 8; ++i) {
         msg.m1 |= (unsigned long long)buf[i]      << (8 * i);
         msg.m2 |= (unsigned long long)buf[i +  8] << (8 * i);
         msg.m3 |= (unsigned long long)buf[i + 16] << (8 * i);
         msg.m4 |= (unsigned long long)buf[i + 24] << (8 * i);
      }
      return true;
   }

   bool Query(unsigned long long cmd, OnlMessage& msg)
   { return Send(cmd) ? Recv(msg) : false; }

   const std::string& IP() const { return fIP; }
   int Port() const { return fPort; }

private:
   OnlSocket(const OnlSocket&);
   OnlSocket& operator=(const OnlSocket&);
   std::string fIP;
   int         fPort;
   int         fFD;
};

// ---- 상태 비트마스크 헬퍼 (onlutils.py 와 동일) -----------------------
inline bool CheckState(unsigned long long st, int state) { return (st >> state) & 1ULL; }
inline bool CheckError(unsigned long long st) { return CheckState(st, onl::kERROR); }
inline int  GetState(unsigned long long st)
{
   for (int n = 1; n < 16; ++n) if ((st >> n) & 1ULL) return n;
   return 0;
}

#endif
