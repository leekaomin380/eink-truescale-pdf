#!/bin/zsh
# 启动 print-to-quaderno 图形界面
cd "${0:A:h}"
python3 gui/server.py "${1:-8777}" &
sleep 1
open "http://127.0.0.1:${1:-8777}"
wait
