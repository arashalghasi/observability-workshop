# Workshop helpers for sending payments through the api-gateway.
# Load in a session with:   . .\scripts\payment-helpers.ps1
# Load in every session:    Add-Content $PROFILE ". `"$PWD\scripts\payment-helpers.ps1`""

function Send-Payment {
    param(
        [string]$PosId = 'POS-01',
        [string]$CardNumber = '5555567898780008',
        [string]$ExpiryDate = '789456123',
        [int]$Amount = 25000
    )
    $body = @{
        posId      = $PosId
        cardNumber = $CardNumber
        expiryDate = $ExpiryDate
        amount     = $Amount
    } | ConvertTo-Json

    try {
        Invoke-RestMethod -Method Post -Uri 'http://localhost:8080/api/easypay/payments' `
            -ContentType 'application/json' -Body $body
    }
    catch {
        # Several chapters deliberately provoke HTTP 500s - show the body, not just the status
        Write-Host "HTTP $([int]$_.Exception.Response.StatusCode)" -ForegroundColor Yellow
        $_.ErrorDetails.Message
    }
}

# Fire N payments in a row, discarding the responses. Traffic generator when k6 is not installed.
function Send-PaymentBurst {
    param(
        [int]$Count = 50,
        [int]$Amount = 40000,
        [string]$PosId = 'POS-01',
        [string]$CardNumber = '5555567898780008'
    )
    1..$Count | ForEach-Object {
        Send-Payment -PosId $PosId -CardNumber $CardNumber -Amount $Amount | Out-Null
    }
    Write-Host "$Count payments sent (amount=$Amount, pos=$PosId)" -ForegroundColor Green
}
