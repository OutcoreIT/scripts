$clienteTag = "OutCore"

# Força TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Configuração do servidor OCS
$ocsServer = "https://inventory.outcore.com.br/ocsinventory"
$zipUrl = "https://github.com/OCSInventory-NG/WindowsAgent/releases/download/2.11.0.1/OCS-Windows-Agent-2.11.0.1_x64.zip"
$cacertUrl = "https://curl.se/ca/cacert.pem"

# Caminhos temporários
$tempPath = "$env:TEMP\OCS-Agent"
$zipPath = "$tempPath\agent.zip"
$extractPath = "$tempPath\extracted"
$cacertPath = "C:\ProgramData\OCS Inventory NG\Agent\cacert.pem"
$iniPath = "C:\Program Files\OCS Inventory Agent\ocsinventory.ini"

# Cria diretório temporário
if (-Not (Test-Path $tempPath)) {
    New-Item -Path $tempPath -ItemType Directory | Out-Null
}

# Baixa o ZIP do instalador
Write-Host "🔽 Baixando o agente OCS..."
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

# Extrai o ZIP
Write-Host "📦 Extraindo arquivos..."
Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

# Encontra o instalador
$installer = Get-ChildItem -Path $extractPath -Filter *.exe -Recurse | Where-Object { $_.Name -like "*setup*" } | Select-Object -First 1
if ($null -eq $installer) {
    Write-Host "❌ Instalador não encontrado após extração."
    exit 1
}

# Instala o agente
Write-Host "⚙️ Instalando o agente..."
$p = Start-Process -FilePath $installer.FullName -ArgumentList "/S /SERVER:$ocsServer /SSL=1 /NO_SYSTRAY /NOW /TAG:$clienteTag" -PassThru -Wait

# Aguarda o instalador encerrar
Start-Sleep -Seconds 5
while (Get-Process | Where-Object { $_.Path -eq $installer.FullName }) {
    Start-Sleep -Seconds 2
}

# Baixa o cacert.pem para validar o certificado HTTPS
Write-Host "🔐 Baixando cacert.pem para validação SSL..."
if (-Not (Test-Path (Split-Path $cacertPath))) {
    New-Item -Path (Split-Path $cacertPath) -ItemType Directory -Force | Out-Null
}
Invoke-WebRequest -Uri $cacertUrl -OutFile $cacertPath -UseBasicParsing

# Cria arquivo de configuração do agente
Write-Host "🛠️ Criando arquivo de configuração ocsinventory.ini..."
if (-Not (Test-Path $iniPath)) {
    New-Item -Path $iniPath -ItemType File -Force | Out-Null
}
Set-Content -Path $iniPath -Value @"
[OCSInventory]
CA_CERTIFICATE=$cacertPath
LOGLEVEL=5
"@

# Executa o agente para envio imediato
Write-Host "🚀 Enviando inventário para o servidor..."
Start-Process -FilePath "C:\Program Files\OCS Inventory Agent\OCSInventory.exe" -ArgumentList "/SSL=1 /SERVER:$ocsServer /NOW /TAG:$clienteTag /debug" -Wait

# Limpa arquivos temporários (com tentativas)
$try = 0
do {
    try {
        Write-Host "🧹 Limpando arquivos temporários (tentativa $($try + 1))..."
        Remove-Item -Path $tempPath -Recurse -Force -ErrorAction Stop
        $success = $true
    } catch {
        $success = $false
        Start-Sleep -Seconds 3
    }
    $try++
} while (-not $success -and $try -lt 3)

if ($success) {
    Write-Host "✅ Instalação do agente OCS concluída com sucesso."
} else {
    Write-Host "⚠️ Instalação concluída, mas não foi possível apagar os arquivos temporários."
}
