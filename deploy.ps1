<#
.SYNOPSIS
    Deploy Matrix + Element to the OpenClaw VM.

.DESCRIPTION
    1. Updates NSG rules (opens ports 80/443) via Bicep redeployment
    2. Copies Matrix config files to the VM via SCP
    3. Runs setup.sh on the VM via SSH

.PARAMETER VmFqdn
    The VM's FQDN (e.g., openclaw-abc123.centralus.cloudapp.azure.com).
    If not provided, queries it from the Azure deployment.

.PARAMETER SkipInfra
    Skip the Bicep redeployment (use if NSG is already updated).

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -VmFqdn "openclaw-abc123.centralus.cloudapp.azure.com"
    .\deploy.ps1 -SkipInfra
#>
param(
    [string]$VmFqdn = "",
    [switch]$SkipInfra
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$OpenClawRepo = Join-Path (Split-Path $RepoRoot) "my-openclaw"
$ConfigDir = Join-Path $RepoRoot "config\matrix"
$ResourceGroup = "openclaw-rg"

Write-Host "`n=== Matrix + Element Deployment ===" -ForegroundColor Cyan

# --- Step 1: Update NSG via Bicep (if not skipped) ---
if (-not $SkipInfra) {
    Write-Host "`n>>> Step 1: Updating NSG to allow HTTP/HTTPS..." -ForegroundColor Yellow

    if (-not (Test-Path $OpenClawRepo)) {
        Write-Error "OpenClaw repo not found at $OpenClawRepo. Please ensure ~/repos/my-openclaw exists."
    }

    # Deploy with skipCustomData=true so we don't re-run cloud-init on the live VM
    Write-Host "  Running az deployment (skipCustomData=true to preserve running VM)..."
    $deployment = az deployment group create `
        --resource-group $ResourceGroup `
        --template-file "$OpenClawRepo\infra\main.bicep" `
        --parameters skipCustomData=true `
        --query "properties.outputs" `
        -o json | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Bicep deployment failed!"
    }

    if (-not $VmFqdn -and $deployment.vmFqdn) {
        $VmFqdn = $deployment.vmFqdn.value
    }
    Write-Host "  NSG updated with HTTP/HTTPS rules ✓" -ForegroundColor Green
}

# --- Resolve FQDN if still empty ---
if (-not $VmFqdn) {
    Write-Host "`n>>> Querying VM FQDN from Azure..."
    $VmFqdn = az deployment group show `
        --resource-group $ResourceGroup `
        --name "main" `
        --query "properties.outputs.vmFqdn.value" `
        -o tsv 2>$null

    if (-not $VmFqdn) {
        Write-Error "Could not determine VM FQDN. Pass it with -VmFqdn parameter."
    }
}
Write-Host "  VM FQDN: $VmFqdn" -ForegroundColor Green

# --- Step 2: Copy config files to VM ---
Write-Host "`n>>> Step 2: Copying Matrix config files to VM..." -ForegroundColor Yellow

$SshUser = "azureuser"
$RemoteDir = "/home/$SshUser/matrix-config"

ssh "${SshUser}@${VmFqdn}" "mkdir -p $RemoteDir"
scp "$ConfigDir\docker-compose.yml" "${SshUser}@${VmFqdn}:${RemoteDir}/"
scp "$ConfigDir\Caddyfile" "${SshUser}@${VmFqdn}:${RemoteDir}/"
scp "$ConfigDir\element-config.json" "${SshUser}@${VmFqdn}:${RemoteDir}/"
scp "$ConfigDir\setup.sh" "${SshUser}@${VmFqdn}:${RemoteDir}/"

Write-Host "  Files copied ✓" -ForegroundColor Green

# --- Step 3: Run setup on VM ---
Write-Host "`n>>> Step 3: Running setup on VM..." -ForegroundColor Yellow
Write-Host "  This will install Docker (if needed), generate Synapse config, and start the stack.`n"

ssh -t "${SshUser}@${VmFqdn}" "chmod +x $RemoteDir/setup.sh && bash $RemoteDir/setup.sh $VmFqdn"

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Cyan
Write-Host "  Element Web: https://$VmFqdn" -ForegroundColor Green
Write-Host "  Create admin user: ssh ${SshUser}@${VmFqdn} 'docker exec -it synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008'" -ForegroundColor Green
