# Badge Finder

Lists Supercon badges heard on the badge link protocol, nearest first: name, SC (our Crystal firmware) or os
(badge os, through a Crystal bridge), estimated distance, bucket (here / near / room / far) and RSSI.
UP/DOWN pick, SELECT opens one badge with a big distance and a warmer/colder trend, BACK goes back.

The RSSI of a Crystal badge is what that badge measured of this BeagleBadge's frames (ESP32 promiscuous mode);
the BeagleBadge's CC33xx driver cannot report it for frames relayed by the access point, and has no FTM.
Model: `d = 10^((-45 - rssi) / 25)` m, max RSSI over 4 s. Expect a factor of 2 either way.
