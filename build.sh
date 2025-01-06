#!/bin/bash

set -x

set

git --version
wget --version
df -h
df -h .

dpkg -l

file /opt/build/bin/build

pstree -apl

ps axuww


exit 2