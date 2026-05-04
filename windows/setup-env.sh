#!/usr/bin/env bash
# Source this file before running `dotnet` commands on macOS:
#   source windows/setup-env.sh
# It puts the user-local .NET 8 SDK on PATH.

export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$HOME/.dotnet:$PATH"

if ! command -v dotnet >/dev/null 2>&1; then
  echo "dotnet not found. Install with:"
  echo "  curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0 --install-dir \"\$HOME/.dotnet\""
  return 1 2>/dev/null || exit 1
fi

dotnet --version
