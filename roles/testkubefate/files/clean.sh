#/bin/bash

CHECK_STATUS_SCRIPT="/tmp/check_status.sh"
CLEAN_SCRIPT="/tmp/clean.sh"

sed -i '/JOB_STATUS/d' ~/.bash_profile

if [ -f $CHECK_STATUS_SCRIPT ]; then
    rm $CHECK_STATUS_SCRIPT
fi

if [ -f $CLEAN_SCRIPT ]; then
    rm $CLEAN_SCRIPT
fi
