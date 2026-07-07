$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/bootstrap.ps1"

Initialize-GmodTools -Root (Split-Path -Parent $PSScriptRoot) -Wiki
