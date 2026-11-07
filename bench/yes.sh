#!/bin/sh
# yes.sh BIN - read 50 MB from an endless `BIN` (poop would never see it exit).
"$1" | head -c 50000000 > /dev/null
exit 0
