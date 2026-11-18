# install.ps1 -- set up an LSD server with one command, on Windows
#
#   irm https://raw.githubusercontent.com/Fran6nd/lsd-docker/master/install.ps1 | iex
#
# The PowerShell twin of install.sh: pulls the image, runs the setup
# wizard into a fresh data volume, and starts the server. Needs Docker
# Desktop. Everything it does is plain docker commands, printed as it
# goes, so nothing here is needed again.
#
# Environment: LSD_IMAGE, LSD_NAME (container), LSD_VOLUME.

$ErrorActionPreference = 'Stop'

$Image  = if ($env:LSD_IMAGE)  { $env:LSD_IMAGE }  else { 'ghcr.io/fran6nd/lsd-docker:latest' }
$Name   = if ($env:LSD_NAME)   { $env:LSD_NAME }   else { 'lsd' }
$Volume = if ($env:LSD_VOLUME) { $env:LSD_VOLUME } else { 'lsd-data' }

function Run {
	Write-Host "+ docker $($args -join ' ')"
	& docker @args
	if ($LASTEXITCODE -ne 0) { throw "docker $($args[0]) failed" }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
	Write-Host 'Docker is not installed: https://docs.docker.com/desktop/setup/install/windows-install/'
	return
}

docker container inspect $Name *> $null
if ($LASTEXITCODE -eq 0) {
	Write-Host "A container named $Name already exists."
	Write-Host "  set it up again:  docker exec -it $Name lsdctl setup"
	Write-Host "  update it:        docker run --rm --volumes-from $Name -v /var/run/docker.sock:/var/run/docker.sock $Image update"
	return
}

# This PC's LAN addresses, for the connect addresses lsdctl prints: a
# container cannot see them itself. Docker's, WSL's and Hyper-V's own
# virtual adapters are left out, as are link-local addresses.
$Addresses = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
	Where-Object {
		$_.IPAddress -ne '127.0.0.1' -and
		$_.IPAddress -notlike '169.254.*' -and
		$_.InterfaceAlias -notmatch 'vEthernet|WSL|Docker|Hyper-V|Loopback|VirtualBox|VMware|Tailscale|WireGuard'
	} | Select-Object -ExpandProperty IPAddress) -join ' '

Run pull $Image
Run volume create $Volume | Out-Null

Run run --rm -it -e "LSD_HOST_ADDRESSES=$Addresses" -v "${Volume}:/data" $Image setup

$Port = (docker run --rm -v "${Volume}:/data" $Image get port).Trim()
Run run -d --name $Name --restart unless-stopped `
	-p "${Port}:${Port}/udp" -e "LSD_HOST_ADDRESSES=$Addresses" `
	-v "${Volume}:/data" $Image | Out-Null

Write-Host ''
Write-Host "The server is starting on port $Port/udp."
docker exec $Name lsdctl address
Write-Host ''
Write-Host "  status:      docker exec $Name lsdctl status"
Write-Host "  scripts:     docker exec $Name lsdctl available"
Write-Host "  everything:  docker exec $Name lsdctl help"
Write-Host "  logs:        docker logs -f $Name"
Write-Host ''
Write-Host 'If Windows Firewall asks about Docker, allow it, or players on your network cannot connect.'
