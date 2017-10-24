# Distribution badges
# Copyright 2017 Federico Ceratto <federico.ceratto@gmail.com>
# Released under AGPLv3 License, see LICENSE file

import asyncdispatch,
  jester,
  osproc,
  strutils,
  tables,
  times

from os import createDir, existsFile
from posix import onSignal, SIGABRT
from httpclient import newHttpClient, getContent
import morelogging

type
  # distro -> flavour -> package name -> version
  PkgsVersion = Table[string, string]
  FlavorPackages = Table[string, PkgsVersion]
  DistroFlavors = Table[string, FlavorPackages]

  DistroMetadata = tuple
    name, flavour, format, pkg_url_tpl, pkg_list_url: string

  BadgeParams = ref object
    w0, w1, logoWidth, logoPadding: int
    color1, color2, logo, sbj, status: string


const
  update_interval_s = 30 * 60
  defaultsfile = "/etc/default/distrobadges"
  distros: seq[DistroMetadata] = @[
    ("debian", "stable", "dpkg",
    "https://packages.$distro.org/$flavour/$pname",
    "http://cdn-fastly.deb.debian.org/debian/dists/wheezy/main/binary-amd64/Packages.bz2"),
    ("debian", "testing", "dpkg",
    "https://packages.$distro.org/$flavour/$pname",
    "http://cdn-fastly.deb.debian.org/debian/dists/testing/main/binary-amd64/Packages.xz"),
    ("debian", "unstable", "dpkg",
    "https://packages.$distro.org/$flavour/$pname",
    "http://cdn-fastly.deb.debian.org/debian/dists/sid/main/binary-amd64/Packages.xz"),
    ("ubuntu", "xenial", "dpkg",
    "http://packages.$distro.org/$flavour/$pname",
    "http://archive.ubuntu.com/ubuntu/dists/xenial/main/binary-amd64/Packages.xz")
  ]

include "templates/index.tmpl"
include "templates/badge-flat.svg"

let log = newJournaldLogger()

var baseurl = "https://badges.debian.net/"
var packages: DistroFlavors

# TODO: handle curl getting an HTML error page instead of tarball

proc xz_unpack_package_list(src, dst: string) =
  ##
  let cmd = "xzgrep -e '^Package: ' -e '^Version: ' $# > $#" % [src, dst]
  log.info("unpacking: $#" % cmd)
  let exit_code = execCmd cmd
  log.debug("Exit code: $#" % $exit_code)
  doAssert exit_code == 0

proc bz_unpack_package_list(src, dst: string) =
  ##
  let cmd = "bzcat $# | grep -e '^Package: ' -e '^Version: ' > $#" % [src, dst]
  log.info "unpacking: $#" % cmd
  let exit_code = execCmd cmd
  log.debug("Exit code: $#" % $exit_code)
  doAssert exit_code == 0

proc dpkg_extract_packages_version(fname: string): PkgsVersion =
  ##
  let t0 = epochTime()
  result = initTable[string, string]()
  var pname = ""
  log.debug("Parsing $#" % fname)
  for line in fname.lines:
    if line.startswith("Package: "):
      if pname != "":
        log.info("Error: unexpected Package line")
      pname = line[9..^0]
    elif line.startswith("Version: "):
      if pname == "":
        log.info("Error: unexpected Version line")
      else:
        if result.haskey pname:
          log.info "duplicate: $#" % pname
        result[pname] = line[9..^0]
        pname = ""
  log.debug("Parsing time: $#" % $(epochTime() - t0))


#proc fetch_package_list(url, fname: string) =
#  ## TODO etag?
#  log.debug "fetching $#" % url
#  let c = newHttpClient().getContent(url)
#  writeFile(fname, c)

proc fetch_package_list(url, fname: string) =
  ## Download or update existing file using curl
  let cmd = "/usr/bin/curl -s -o $# -z $# $#" % [fname, fname, url]
  log.debug "updating file list using: $#" % cmd
  let t0 = epochTime()
  let exit_code = execCmd cmd
  doAssert exit_code == 0
  log.debug "done in $#" % $(epochTime() - t0)

proc estimate_text_width(t: string): int =
  return t.len * 7

proc render_badge(distro, flavour, pname, version: string): string =
  let color_left =
    case distro
    of "debian": "#dd1155"
    of "ubuntu": "#e95420"
    of "suse": "#02d35f"
    else: "#aaaaaa"
  let sbj = distro & " " & flavour
  var b = BadgeParams(
    color1:color_left,
    color2:"#303030",
    logo:"",
    sbj:"$# $#" % [distro.capitalizeAscii(), flavour.capitalizeAscii()],
    status:version,
  )
  b.w0 = b.sbj.estimate_text_width + 10 + b.logoWidth + b.logoPadding
  b.w1 = b.status.estimate_text_width + 10
  let badge = generate_badge(b)
  return badge


proc filter_user_input(inp: string): string =
  ## Filter user input
  const allowed = Letters + Digits + {'_', '-', '~'}
  result = newStringOfCap(inp.len)
  for c in inp:
    if c in allowed:
      result.add c


settings: port = 7700.Port

routes:

  get "/":
    resp generate_index(baseurl, "DISTRIBUTION", "FLAVOUR", "PACKAGE_NAME", "")

  post "/":
    let tokens = @"distro_and_flavour".split('|')
    if tokens.len != 2:
      halt("huh?")
    let
      distro = filter_user_input tokens[0]
      flavour = filter_user_input tokens[1]
      pname = filter_user_input(@"pname")
      pkg_directory_url_tpl =
        if distro == "debian":
          "https://packages.debian.org/$flavour/$pname"
        elif distro == "ubuntu":
          "http://packages.ubuntu.com/$flavour/$pname"
        else:
          ""
      pkg_directory_url = pkg_directory_url_tpl.replace("$distro", distro)
        .replace("$flavour", flavour).replace("$pname", pname)

    resp generate_index(baseurl, distro, flavour, pname, pkg_directory_url)

  get "/badges/@distro/@flavour/@pkg_name/version.svg":
    let
      distro = filter_user_input(@"distro")
      flavour = filter_user_input(@"flavour")
      pname = filter_user_input(@"pkg_name")
    let version =
      try:
        packages[distro][flavour][pname]
      except KeyError:
        "none"
    log.debug("serving distro $# flavour $# pname $# version $#" % [
      distro, flavour, pname, version])
    let badge = render_badge(distro, flavour, pname, version)
    let etag = "$#-$#-$#-$#" % [distro, flavour, pname, version]
    response.data.headers["ETag"] = etag
    response.data.headers["Cache-Control"] = "max-age=600, must-revalidate, public"
    resp(badge, contentType = "image/svg+xml")

proc parse_defaults() =
  baseurl = "https://badges.debian.net"
  try:
    for line in defaultsfile.lines:
      if line.startswith("baseurl="):
        baseurl = line[8..^1]
        log.info("Setting baseurl '$#'" % baseurl)
  except:
    discard

proc init_packages() =
  ## init packages structure
  packages = initTable[string, FlavorPackages]()
  for distro in distros:
    if not packages.hasKey distro.name:
      packages[distro.name] = initTable[string, PkgsVersion]()

proc update_packages() =
  ## Fetch/update package lists from distribution repos
  ## Extract package name and version and update the `packages` structure
  for distro in distros:

    let cfn = "$#-$#.compressedlist" % [distro.name, distro.flavour]
    let fn = "$#-$#.list" % [distro.name, distro.flavour]
    fetch_package_list(distro.pkg_list_url, cfn)
    case distro.format
    of "dpkg":
      if distro.pkg_list_url.endswith("xz"):
        xz_unpack_package_list(cfn, fn)
      elif distro.pkg_list_url.endswith("bz2"):
        bz_unpack_package_list(cfn, fn)
      else:
        log.error "unknown compression"
        return
    else:
      log.error "Unknown format $#" % distro.format
      return

    packages[distro.name][distro.flavour] = dpkg_extract_packages_version fn

proc run_packages_list_updater() {.async.} =
  ## Call update_packages() forever
  while true:
    await sleepAsync(update_interval_s * 1000)
    log.info("Starting packages update")
    update_packages()
    log.info("Package update completed")

proc main() =
  log.info("Starting distrobadges")
  parse_defaults()
  init_packages()
  update_packages()
  asyncCheck run_packages_list_updater()
  log.info "starting"
  runForever()


onSignal(SIGABRT):
  ## Handle SIGABRT from systemd
  log.debug("Received SIGABRT")
  quit(1)

when isMainModule:
  main()
