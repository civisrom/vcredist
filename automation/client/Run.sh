#!/usr/bin/env bash
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
test "${RUNNER_ENVIRONMENT:-}" = github-hosted
test -c /dev/kvm || { echo 'KVM is unavailable; client Windows tests cannot run.' >&2; exit 1; }
case "${CLIENT_OS:-}" in windows-10|windows-11) ;; *) exit 2 ;; esac

root="$GITHUB_WORKSPACE"
work="$RUNNER_TEMP/client-windows"
mkdir -p "$work/storage" "$work/shared" "$work/oem"
# Only unused toolchains on this disposable runner, never repository data.
echo "Preparing disk space for $CLIENT_OS..."
sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache
available=$(df --output=avail -B1 "$work" | tail -n 1)
(( available >= 40 * 1024 * 1024 * 1024 )) || { echo 'At least 40 GiB of free space is required.' >&2; exit 1; }

catalog="$root/automation/client/images.json"
url=$(jq -r --arg os "$CLIENT_OS" '.[$os].url' "$catalog")
checksum=$(jq -r --arg os "$CLIENT_OS" '.[$os].sha256' "$catalog")
container=$(jq -r '.container' "$catalog")
[[ "$url" == https://software-static.download.prss.microsoft.com/*.iso ]]
echo "Downloading the official $CLIENT_OS evaluation ISO..."
curl --fail --show-error --silent --proto '=https' --max-time 900 --retry 3 --write-out 'Downloaded %{size_download} bytes at %{speed_download} bytes/s\n' "$url" -o "$work/storage/windows.iso"
printf '%s  %s\n' "$checksum" "$work/storage/windows.iso" | sha256sum -c -

cp -r "$root/automation" "$root/installer" "$work/shared/"
mkdir -p "$work/shared/dist"
cp "$root/.build/dist/"* "$work/shared/dist/"
printf '%s\n' "$CLIENT_OS" > "$work/shared/platform.txt"
cp "$root/automation/client/Guest.ps1" "$work/oem/Guest.ps1"
printf '@echo off\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\OEM\\Guest.ps1\r\n' > "$work/oem/install.bat"

# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  if [[ -n "${log_pid:-}" ]]; then kill "$log_pid" 2>/dev/null || true; fi
  docker logs runtime-windows --tail 80 || true
  docker rm --force runtime-windows >/dev/null 2>&1 || true
}
trap cleanup EXIT
echo "Starting the disposable $CLIENT_OS VM..."
docker run --detach --name runtime-windows --device=/dev/kvm --device=/dev/net/tun --cap-add NET_ADMIN \
  --env RAM_SIZE=8G --env CPU_CORES=4 --env DISK_SIZE=64G \
  --env DISK_FMT=qcow2 --env ALLOCATE=N --env BOOT_MODE=windows_secure \
  --volume "$work/storage:/storage" --volume "$work/storage/windows.iso:/custom.iso:ro" \
  --volume "$work/shared:/shared" --volume "$work/oem:/oem:ro" \
  "$container"

# Stream only guest test output. No tokens, host home or Docker socket enter the VM.
touch "$work/shared/guest.log"
tail --follow=name --retry "$work/shared/guest.log" &
log_pid=$!
deadline=$((SECONDS + 6600))
while (( SECONDS < deadline )); do
  if [[ -s "$work/shared/result.json" ]]; then
    kill "$log_pid" || true
    cat "$work/shared/result.json"
    jq --exit-status --arg os "$CLIENT_OS" '.platform == $os and .success == true and .rebootVerified == true' "$work/shared/result.json" >/dev/null
    exit 0
  fi
  [[ $(docker inspect --format '{{.State.Running}}' runtime-windows) == true ]] || exit 1
  sleep 20
done
kill "$log_pid" || true
echo 'Client Windows installation or tests exceeded 110 minutes.' >&2
exit 1
