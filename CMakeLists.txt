cmake_minimum_required(VERSION 3.16)
project(RENE-daq-rcterm LANGUAGES CXX)

# ---------------------------------------------------------------------
#  RENE / CUPDAQ  text-mode run control
#    rcterm       : run control (1 run per invocation, or self-rotating)
#    rcsupervisor : watchdog / run rotator (separate process)
#
#  CUPDAQ 라이브러리에는 의존하지 않는다. rc.py 와 동일하게 TCP 소켓
#  프로토콜로만 DAQ 프로세스와 통신하므로 ROOT + glibc 만 필요하다.
# ---------------------------------------------------------------------

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "build type" FORCE)
endif()

find_package(ROOT REQUIRED COMPONENTS Core RIO Tree)

message(STATUS "ROOT version : ${ROOT_VERSION}")
message(STATUS "ROOT prefix  : ${ROOT_PREFIX}")

# ---- rcterm ---------------------------------------------------------
add_executable(rcterm
  src/rcterm.cc
  src/RunControl.cc
)

# ---- rcsupervisor ---------------------------------------------------
add_executable(rcsupervisor
  src/rcsupervisor.cc
)

foreach(tgt rcterm rcsupervisor)
  target_include_directories(${tgt} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
  target_compile_options(${tgt} PRIVATE -Wall -Wextra -Wno-unused-parameter)
  if(TARGET ROOT::Core)
    target_link_libraries(${tgt} PRIVATE ROOT::Core ROOT::RIO ROOT::Tree)
  else()
    # 구버전 ROOT : imported target 이 없을 때
    include(${ROOT_USE_FILE})
    target_include_directories(${tgt} PRIVATE ${ROOT_INCLUDE_DIRS})
    target_link_libraries(${tgt} PRIVATE ${ROOT_LIBRARIES})
  endif()
endforeach()

install(TARGETS rcterm rcsupervisor RUNTIME DESTINATION bin)
install(PROGRAMS scripts/killdaq.sh DESTINATION bin)
install(DIRECTORY config/ DESTINATION share/rcterm)
