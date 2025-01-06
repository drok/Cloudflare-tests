#!/bin/bash

set

git --version
wget --version
df -h
df -h .

dpkg -l

echo FILE TYPE :::::::::::::::::::::::::::::
file /opt/build/bin/build

set -x

pstree -apl

ps axuww

echo /opt/pages/build_tool/run_build.sh ::::::::::::::::::::
cat /opt/pages/build_tool/run_build.sh


echo EXITING WITH ERROR
exit 2