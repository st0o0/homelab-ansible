<#
.SYNOPSIS
  Manage the dev container without VS Code, via the devcontainer CLI.

.DESCRIPTION
  Requires Node/npx. Falls back to `npx --yes @devcontainers/cli` if the
  `devcontainer` CLI isn't installed globally.

.PARAMETER Command
  up        create/start container
  down      stop container
  rebuild   remove + rebuild (--no-cache)
  shell     open a shell inside the container
  exec      run a command inside the container (pass it via -Args)

.PARAMETER Variant
  Which .devcontainer/<variant>/devcontainer.json to use. Default: windows.

.PARAMETER Args
  Extra arguments, used with `exec` (the command to run inside the container).

.EXAMPLE
  .\devcontainer.ps1 up
  .\devcontainer.ps1 rebuild
  .\devcontainer.ps1 rebuild -Variant linux
  .\devcontainer.ps1 exec -Args bash, -lc, "ansible --version"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("up", "down", "rebuild", "shell", "exec", "help")]
    [string]$Command = "help",

    [ValidateSet("linux", "windows")]
    [string]$Variant = "windows",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceFolder = Resolve-Path (Join-Path $ScriptDir "..")
$Config = Join-Path $ScriptDir "$Variant/devcontainer.json"

if (-not (Test-Path $Config)) {
    Write-Error "No devcontainer.json for variant '$Variant' at $Config"
    exit 1
}

if (Get-Command devcontainer -ErrorAction SilentlyContinue) {
    $Devcontainer = @("devcontainer")
}
else {
    $Devcontainer = @("npx", "--yes", "@devcontainers/cli")
}

function Invoke-Devcontainer {
    param([string[]]$CliArgs)
    $exe = $Devcontainer[0]
    $exeArgs = @($Devcontainer[1..($Devcontainer.Length - 1)]) + $CliArgs
    & $exe @exeArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

switch ($Command) {
    "up" {
        Invoke-Devcontainer @(
            "up",
            "--workspace-folder", $WorkspaceFolder,
            "--config", $Config
        )
    }
    "down" {
        $cid = (docker ps -q --filter "label=devcontainer.local_folder=$WorkspaceFolder")
        if (-not $cid) {
            Write-Host "no running container for $WorkspaceFolder"
        }
        else {
            docker stop $cid
        }
    }
    "rebuild" {
        Invoke-Devcontainer @(
            "up",
            "--workspace-folder", $WorkspaceFolder,
            "--config", $Config,
            "--remove-existing-container",
            "--build-no-cache"
        )
    }
    "shell" {
        # docker/devcontainer exec doesn't forward the calling terminal's
        # TERM by default, which can make a real terminal render
        # Unicode/Powerline glyphs differently than it does outside the
        # container. Forward it explicitly.
        $termValue = if ($env:TERM) { $env:TERM } else { "xterm-256color" }
        Invoke-Devcontainer @(
            "exec",
            "--workspace-folder", $WorkspaceFolder,
            "--config", $Config,
            "--remote-env", "TERM=$termValue",
            "zsh"
        )
    }
    "exec" {
        if (-not $Args -or $Args.Count -eq 0) {
            Write-Error "exec requires a command, e.g.: .\devcontainer.ps1 exec -Args bash, -lc, 'echo hi'"
            exit 1
        }
        $termValue = if ($env:TERM) { $env:TERM } else { "xterm-256color" }
        Invoke-Devcontainer (@(
            "exec",
            "--workspace-folder", $WorkspaceFolder,
            "--config", $Config,
            "--remote-env", "TERM=$termValue"
        ) + $Args)
    }
    default {
        Get-Help $MyInvocation.MyCommand.Path -Detailed
    }
}
