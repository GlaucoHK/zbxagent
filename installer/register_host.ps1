param(
    [string]$apiUrl,
    [string]$user,
    [string]$pass,
    [string]$hostname
)

$templateName = 'RMM Agent Template'
$groupid = '2'

# Login
$loginBody = @{
    jsonrpc = "2.0"
    method  = "user.login"
    params  = @{ username = $user; password = $pass }
    id      = 1
} | ConvertTo-Json -Compress

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType "application/json" -Body $loginBody
    if ($response.error) { throw $response.error.data }
    $token = $response.result
} catch {
    Write-Host "Erro no login: $_"
    exit 1
}

# Headers com token
$headers = @{
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer $token"
}

# Obter template
$templateBody = @{
    jsonrpc = "2.0"
    method  = "template.get"
    params  = @{ output = "extend"; filter = @{ host = $templateName } }
    id      = 2
} | ConvertTo-Json -Compress

try {
    $respTemplate = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $templateBody
    if ($respTemplate.error) { throw $respTemplate.error.data }
    if ($respTemplate.result.Count -eq 0) { throw "Template '$templateName' não encontrado" }
    $templateId = $respTemplate.result[0].templateid
} catch {
    Write-Host "Erro ao obter template: $_"
    exit 1
}

# Criar host
$hostBody = @{
    jsonrpc = "2.0"
    method  = "host.create"
    params  = @{
        host       = $hostname
        interfaces = @(
            @{
                type = 1
                main = 1
                useip = 1
                ip   = "127.0.0.1"
                dns  = ""
                port = "10050"
            }
        )
        groups    = @(@{ groupid = $groupid })
        templates = @(@{ templateid = $templateId })
    }
    id = 3
} | ConvertTo-Json -Depth 5 -Compress

try {
    $respHost = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $hostBody
    if ($respHost.error) {
        if ($respHost.error.data -like "*already exists*") {
            Write-Host "Host '$hostname' já existe. Continuando..."
            exit 0
        }
        throw $respHost.error.data
    }
    Write-Host "Host '$hostname' criado com sucesso."
} catch {
    Write-Host "Erro ao criar host: $_"
    exit 1
}