# Regenerates the custom global-hook overload fragment (types/wp_hook_overloads.lua) from
# world-portals' hook.Call/hook.Run sites, so a consumer's hook.Add("wp-...", fn) callback
# types its payload params. Auto-generated. CI: generate-hook-types.yml.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/bootstrap.ps1"

Build-GlobalHookOverloads -Root (Split-Path -Parent $PSScriptRoot) -Id wp
