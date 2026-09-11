#!/bin/sh
set -eu
url=https://raw.githubusercontent.com/omar-ali-1/CompilerPython/master/haos/legacy-install.sh
curl -fsSL "$url" -o /tmp/haos-legacy-install.sh
exec sh /tmp/haos-legacy-install.sh
