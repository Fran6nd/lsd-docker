# play.ps1 -- a casual LAN game of Ace of Spades, gone when it is over (Windows)
# Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
#
#   irm https://raw.githubusercontent.com/Fran6nd/lsd-docker/master/play.ps1 | iex
#
# With the game and map given (piping into iex takes no arguments):
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Fran6nd/lsd-docker/master/play.ps1))) babel random
#
# The PowerShell twin of play.sh: a throwaway server (docker run --rm,
# no volume kept) that asks which game (ctf, babel) and map (random, or
# an aos.party link or id) unless told, prints the address friends on
# your network join with, and stops by itself a minute after the last
# player leaves -- Ctrl-C stops it at once. Then the container is gone,
# and so is the image, if this script downloaded it and nothing else
# uses it. Needs Docker Desktop.
#
# Environment: LSD_IMAGE, LSD_PORT (the first port to try, 32887).

$ErrorActionPreference = 'Stop'

$Image = if ($env:LSD_IMAGE) { $env:LSD_IMAGE } else { 'ghcr.io/fran6nd/lsd-docker:latest' }
$Port  = if ($env:LSD_PORT)  { [int]$env:LSD_PORT } else { 32887 }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
	Write-Host 'Docker is needed: https://docs.docker.com/desktop/setup/install/windows-install/'
	return
}
docker info *> $null
if ($LASTEXITCODE -ne 0) {
	Write-Host 'Docker is installed but not running: start Docker Desktop.'
	return
}

# Was the image here already? Then it is somebody's -- a server of yours,
# say -- and stays (updated, see below). Only an image this game
# downloaded goes with it.
docker image inspect $Image *> $null
$HadImage = ($LASTEXITCODE -eq 0)

# The first free UDP port: a server already running keeps its own.
$Start = $Port
while ($true) {
	$taken = (docker ps --format '{{.Ports}}') -match ":$Port->"
	if (-not $taken) {
		$taken = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue
	}
	if (-not $taken) { break }
	$Port++
	if ($Port -ge $Start + 100) { Write-Host "No free UDP port from $Start."; return }
}

# This computer's LAN addresses, which a container cannot see: the ones
# to give friends. As install.ps1 finds them.
$Addresses = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
	Where-Object {
		$_.IPAddress -ne '127.0.0.1' -and
		$_.IPAddress -notlike '169.254.*' -and
		$_.InterfaceAlias -notmatch 'vEthernet|WSL|Docker|Hyper-V|Loopback|VirtualBox|VMware|Tailscale|WireGuard'
	} | Select-Object -ExpandProperty IPAddress) -join ' '

try {
	# Always the newest image: one line has to be enough, and an old
	# copy left here may predate `play`. Pulling only moves the tag -- a
	# server running on the old image keeps it. Offline, a copy already
	# here will do.
	if (-not $HadImage) {
		Write-Host 'Downloading the game (removed again when it is over)...'
		docker pull -q $Image | Out-Null
	} else {
		Write-Host 'Checking for a newer version of the game...'
		docker pull -q $Image *> $null
		if ($LASTEXITCODE -ne 0) { Write-Host 'Offline? Playing the copy already here.' }
	}
	docker run --rm -it -p "${Port}:32887/udp" `
		-e "LSD_HOST_ADDRESSES=$Addresses" -e "LSD_HOST_PORT=$Port" `
		$Image play @args
}
finally {
	if (-not $HadImage -and -not (docker ps -aq --filter "ancestor=$Image")) {
		docker image rm $Image *> $null
		if ($LASTEXITCODE -eq 0) { Write-Host "Removed the game's image ($Image)." }
	}
}
