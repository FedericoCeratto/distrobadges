# Package

version       = "0.1.1"
author        = "Federico Ceratto"
description   = "Distribution badges"
license       = "AGPLv3"
bin           = @["distrobadges"]

# Dependencies

requires "nim >= 0.16.0", "morelogging", "zip", "jester"

task build_prod, "Build production release":
  exec "nim c -d:release -d:systemd distrobadges.nim"
