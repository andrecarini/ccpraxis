# Don't use $ErrorActionPreference='Stop' — Docker writes to stderr for normal
# "not found" results, and PowerShell 5.1 treats any stderr as a terminating error.

if ($args.Count -gt 0) {
    $ProjectPath = Resolve-Path $args[0]
} else {
    $ProjectPath = Get-Location
}
$ProjectPath = $ProjectPath.ToString().TrimEnd('\')
$ProjectName = (Split-Path $ProjectPath -Leaf).ToLower() -replace ' ', '-'
$ClaudeHostConfig = "$env:USERPROFILE\.claude"
$ContainerConfig = "$ClaudeHostConfig\claude-code-config\container-config"
$LauncherDir = "$ProjectPath\.claude-data\.launcher"

# --- Auto-setup if needed ---

if (-not (Test-Path "$ProjectPath\.claude-data")) {
    Write-Host ""
    Write-Host "======================================================"
    Write-Host "  First-time setup needed for this project."
    Write-Host "  Launching Claude to configure interactively..."
    Write-Host "  Run /sandbox when Claude starts."
    Write-Host "======================================================"
    Write-Host ""
    Push-Location $ProjectPath
    claude
    Pop-Location
    if (-not (Test-Path "$ProjectPath\.claude-data")) {
        Write-Host "Setup was not completed. Aborting."
        exit 1
    }
}

# --- Ensure launcher metadata dir ---
New-Item -ItemType Directory -Force -Path $LauncherDir | Out-Null

# --- Get host Claude Code version ---
$HostVersion = (claude --version 2>$null) -split ' ' | Select-Object -First 1

# --- Build image if needed ---
function Get-DockerfileHash {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.IO.File]::ReadAllBytes("$ContainerConfig\Dockerfile")
    [System.BitConverter]::ToString($md5.ComputeHash($bytes)).Replace('-','').ToLower()
}

function Get-LauncherHash {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $stream = New-Object System.IO.MemoryStream
    foreach ($f in @("$ContainerConfig\bin\claude-sandbox.sh", "$ContainerConfig\bin\claude-sandbox.ps1")) {
        if (Test-Path $f) { $b = [System.IO.File]::ReadAllBytes($f); $stream.Write($b, 0, $b.Length) }
    }
    [System.BitConverter]::ToString($md5.ComputeHash($stream.ToArray())).Replace('-','').ToLower()
}

function Build-Image {
    Write-Host "Building claude-sandbox image with Claude Code v${HostVersion}..."
    docker build `
        --build-arg "CLAUDE_VERSION=$HostVersion" `
        -t "claude-sandbox:$HostVersion" `
        -t "claude-sandbox:latest" `
        $ContainerConfig
    # Save Dockerfile hash so we detect changes later
    Get-DockerfileHash | Set-Content "$LauncherDir\dockerfile-hash" -NoNewline
}

$null = docker image inspect claude-sandbox:latest 2>&1
if ($LASTEXITCODE -ne 0) {
    Build-Image
}

# --- Get or generate container name ---
$ContainerNameFile = "$LauncherDir\container-name"
if (Test-Path $ContainerNameFile) {
    $ContainerName = (Get-Content $ContainerNameFile -Raw).Trim()
} else {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = [System.BitConverter]::ToString(
        $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ProjectPath))
    ).Replace('-','').Substring(0,8).ToLower()
    $ContainerName = "claude-$ProjectName-$hash"
    $ContainerName | Set-Content $ContainerNameFile -NoNewline
}

# --- Staleness check ---
$StaleReasons = @()

$VersionFile = "$LauncherDir\claude-version"
if (Test-Path $VersionFile) {
    $ContainerVersion = (Get-Content $VersionFile -Raw).Trim()
    if ($ContainerVersion -ne $HostVersion) {
        $StaleReasons += "  - Claude Code version mismatch: container has v$ContainerVersion, host has v$HostVersion"
    }
}

$CreatedFile = "$LauncherDir\container-created"
if (Test-Path $CreatedFile) {
    $Created = [datetime]::Parse((Get-Content $CreatedFile -Raw).Trim())
    $AgeDays = ([datetime]::UtcNow - $Created).Days
    if ($AgeDays -gt 7) {
        $StaleReasons += "  - Container is $AgeDays days old"
    }
}

$DockerfileHashFile = "$LauncherDir\dockerfile-hash"
$CurrentHash = Get-DockerfileHash
if (Test-Path $DockerfileHashFile) {
    $SavedHash = (Get-Content $DockerfileHashFile -Raw).Trim()
    if ($SavedHash -ne $CurrentHash) {
        $StaleReasons += "  - Dockerfile has changed since last build"
    }
} else {
    $StaleReasons += "  - Dockerfile has changed since last build"
}

$LauncherHashFile = "$LauncherDir\launcher-hash"
$CurrentLauncherHash = Get-LauncherHash
if (Test-Path $LauncherHashFile) {
    $SavedLauncherHash = (Get-Content $LauncherHashFile -Raw).Trim()
    if ($SavedLauncherHash -ne $CurrentLauncherHash) {
        $StaleReasons += "  - Launcher scripts have changed since container was created"
    }
} else {
    $StaleReasons += "  - Launcher scripts have changed since container was created"
}

if ($StaleReasons.Count -gt 0) {
    Write-Host ""
    Write-Host "WARNING: Container may be stale:"
    $StaleReasons | ForEach-Object { Write-Host $_ }
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  [r] Rebuild - fresh container with Claude Code v$HostVersion"
    Write-Host "  [c] Continue as-is"
    Write-Host ""
    $Choice = Read-Host "Choice [r/c]"
    if ($Choice -eq 'r') {
        $null = docker rm -f $ContainerName 2>&1
        Build-Image
        # Regenerate container name
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $hash = [System.BitConverter]::ToString(
            $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ProjectPath))
        ).Replace('-','').Substring(0,8).ToLower()
        $ContainerName = "claude-$ProjectName-$hash"
        $ContainerName | Set-Content $ContainerNameFile -NoNewline
    }
}

# --- Discover all available skills ---
$AvailableSkills = [ordered]@{}  # name -> {source, path}

# Custom skills (non-host-only)
$SkillsDir = "$ClaudeHostConfig\claude-code-config\skills"
if (Test-Path $SkillsDir) {
    Get-ChildItem -Directory $SkillsDir | ForEach-Object {
        $SkillMd = Join-Path $_.FullName "SKILL.md"
        if (Test-Path $SkillMd) {
            $IsHostOnly = Select-String -Path $SkillMd -Pattern 'host-only: true' -Quiet
            if (-not $IsHostOnly) {
                $AvailableSkills[$_.Name] = @{ source = 'custom'; path = $_.FullName }
            }
        }
    }
}

# Plugin skills
$InstalledPluginsFile = "$ClaudeHostConfig\plugins\installed_plugins.json"
if (Test-Path $InstalledPluginsFile) {
    $PluginData = Get-Content $InstalledPluginsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in $PluginData.plugins.PSObject.Properties) {
        $pluginLabel = ($entry.Name -split '@')[0]
        $installs = @($entry.Value)
        $latest = $installs[-1]
        $installPath = $latest.installPath
        $pSkillsDir = Join-Path $installPath "skills"
        if (Test-Path $pSkillsDir) {
            Get-ChildItem -Directory $pSkillsDir | ForEach-Object {
                $AvailableSkills[$_.Name] = @{ source = "plugin:$pluginLabel"; path = $_.FullName }
            }
        }
    }
}

# --- Skill selection (saved per project, re-prompt on new skills) ---
$SelectionFile = "$LauncherDir\selected-skills.json"
$AvailableNames = @($AvailableSkills.Keys)
$NeedPrompt = $true
$SelectedNames = @()

if (Test-Path $SelectionFile) {
    $Saved = Get-Content $SelectionFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $NewSkills = @($AvailableNames | Where-Object { $Saved.known -notcontains $_ })
    if ($NewSkills.Count -eq 0) {
        $SelectedNames = @($Saved.selected)
        $NeedPrompt = $false
    } else {
        Write-Host ""
        Write-Host "New skills available: $($NewSkills -join ', ')"
        # Pre-select previously selected skills
        $SelectedNames = @($Saved.selected)
    }
}

if ($NeedPrompt -and $AvailableNames.Count -gt 0) {
    Write-Host ""
    Write-Host "Available skills for this sandbox:"
    for ($i = 0; $i -lt $AvailableNames.Count; $i++) {
        $name = $AvailableNames[$i]
        $src = $AvailableSkills[$name].source
        $marker = if ($SelectedNames -contains $name) { 'x' } else { ' ' }
        Write-Host "  [$marker] $($i + 1). $name ($src)"
    }
    Write-Host ""
    $input = Read-Host "Toggle by number (comma-separated), 'a' for all, Enter to confirm"
    if ($input -eq 'a') {
        $SelectedNames = $AvailableNames
    } elseif ($input -ne '') {
        $toggleNums = $input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
        foreach ($num in $toggleNums) {
            $idx = [int]$num - 1
            if ($idx -ge 0 -and $idx -lt $AvailableNames.Count) {
                $name = $AvailableNames[$idx]
                if ($SelectedNames -contains $name) {
                    $SelectedNames = @($SelectedNames | Where-Object { $_ -ne $name })
                } else {
                    $SelectedNames += $name
                }
            }
        }
    }
    # Save selection
    @{ selected = $SelectedNames; known = $AvailableNames } |
        ConvertTo-Json | Set-Content $SelectionFile -Encoding UTF8
}

# --- Build skill mounts from selection ---
$SkillMounts = @()
foreach ($name in $SelectedNames) {
    if ($AvailableSkills.Contains($name)) {
        $SkillMounts += '-v'
        $SkillMounts += "$($AvailableSkills[$name].path):/home/claude/.claude/skills/${name}:ro"
    }
}

# --- Extra env for deploy key ---
$ExtraEnv = @()
if (Test-Path "$ProjectPath\.claude-data\git-ssh-command.sh") {
    $ExtraEnv += '-e'
    $ExtraEnv += 'GIT_SSH_COMMAND=/home/claude/.claude/git-ssh-command.sh'
} elseif (Test-Path "$ProjectPath\deploy_key") {
    $ExtraEnv += '-e'
    $ExtraEnv += 'GIT_SSH_COMMAND=ssh -i /project/deploy_key -o StrictHostKeyChecking=no'
}

# --- PAT auth support ---
$ExtraMounts = @()
if (Test-Path "$ProjectPath\.claude-data\git-askpass.sh") {
    $ExtraMounts += '-v'
    $ExtraMounts += "$ProjectPath\.claude-data\git-askpass.sh:/home/claude/.claude/git-askpass.sh:ro"
    $ExtraMounts += '-v'
    $ExtraMounts += "$ProjectPath\.claude-data\git-pat:/home/claude/.claude/git-pat:ro"
    $ExtraEnv += '-e'
    $ExtraEnv += 'GIT_ASKPASS=/home/claude/.claude/git-askpass.sh'
}

# --- SSH command script mount (when using git-ssh-command.sh) ---
if (Test-Path "$ProjectPath\.claude-data\git-ssh-command.sh") {
    $ExtraMounts += '-v'
    $ExtraMounts += "$ProjectPath\.claude-data\git-ssh-command.sh:/home/claude/.claude/git-ssh-command.sh:ro"
}

# --- Fix ownership for UID consistency (dev container creates root-owned files) ---
$ClaudeUid = 1000
$HasWrong = docker run --rm -u root --entrypoint /bin/bash `
    -v "${ProjectPath}:/data" `
    claude-sandbox:latest -c "find /data -maxdepth 2 -not -user $ClaudeUid -not -path '/data/.git/*' -print -quit 2>/dev/null" 2>$null
$HasWrong = ($HasWrong | Out-String).Trim()
if ($HasWrong) {
    Write-Host "Fixing project ownership (setting to UID $ClaudeUid)..."
    docker run --rm -u root --entrypoint /bin/bash `
        -v "${ProjectPath}:/data" `
        claude-sandbox:latest -c "find /data -not -user $ClaudeUid -not -path '/data/.git/*' -print0 2>/dev/null | xargs -0 -r chown ${ClaudeUid}:${ClaudeUid}" 2>$null
}

# --- Ensure writable claude.json in project (template from container-config) ---
$ClaudeJsonProject = "$ProjectPath\.claude-data\.claude.json"
$ClaudeJsonTemplate = "$ContainerConfig\claude.json"
if (-not (Test-Path $ClaudeJsonProject) -and (Test-Path $ClaudeJsonTemplate)) {
    Copy-Item $ClaudeJsonTemplate $ClaudeJsonProject
}

# --- Create container if needed ---
$null = docker inspect $ContainerName 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "Reattaching to existing container: $ContainerName"
} else {
    Write-Host "Creating new container: $ContainerName"

    # Save metadata
    $HostVersion | Set-Content "$LauncherDir\claude-version" -NoNewline
    [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss') | Set-Content "$LauncherDir\container-created" -NoNewline
    Get-LauncherHash | Set-Content "$LauncherDir\launcher-hash" -NoNewline

    $DockerArgs = @(
        'create', '-it'
        '--name', $ContainerName
        '--hostname', 'claude-sandbox'
        '-p', '9000-9009:9000-9009'
    )
    $DockerArgs += $ExtraEnv
    $DockerArgs += @(
        '-v', "${ProjectPath}:/project"
        '-v', "${ProjectPath}\.claude-data:/home/claude/.claude"
        '-v', "${LauncherDir}:/home/claude/.claude/.launcher:ro"
        '-v', "${ProjectPath}\.claude-data\.claude.json:/home/claude/.claude.json"
        '-v', "${ClaudeHostConfig}\.credentials.json:/home/claude/.claude/.credentials.json"
        '-v', "${ContainerConfig}\CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro"
        '-v', "${ContainerConfig}\settings.json:/home/claude/.claude/settings.json:ro"
        '-v', "${ClaudeHostConfig}\claude-code-config\scripts\statusline.pl:/home/claude/.claude/statusline.pl:ro"
    )
    $DockerArgs += $SkillMounts
    $DockerArgs += $ExtraMounts
    $DockerArgs += 'claude-sandbox:latest'

    & docker @DockerArgs | Out-Null
}

docker start -ai $ContainerName
