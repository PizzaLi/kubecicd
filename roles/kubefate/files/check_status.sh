#/bin/bash

source ~/.bash_profile
if [ -z "$JOB_STATUS" ]; then
  echo "export JOB_STATUS=running" >> ~/.bash_profile
  exit 0
else
  echo "Another job is running on this host"
  exit 1
fi
