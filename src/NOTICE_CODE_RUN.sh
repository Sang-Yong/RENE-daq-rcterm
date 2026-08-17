#!/bin/bash 

NOTICEDIR="/home/frontend/DAQ/NOTICE/nkfadc500_CNU/notice"
FADCDIR="${NOTICEDIR}/test/nkfadc500"
SADCDIR="${NOTICEDIR}/test/m64adc"

cd ${NOTICEDIR}

source notice_env.sh 


# SADC
cd ${SADCDIR}
root -l -b -q sadc_.C

# FADC
cd ${FADCDIR}
root -l -b -q fadc_.C
