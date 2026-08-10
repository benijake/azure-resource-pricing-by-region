<#
.SYNOPSIS
Builds a current Azure retail pricing matrix for user-defined resource queries and regions.

.DESCRIPTION
Queries the Azure Retail Prices API for each resource query across each requested region.
Each query can specify any combination of serviceName, productName, skuName, armSkuName,
meterName, serviceFamily, unitOfMeasure, and priceType.

The output contains one row per distinct current price variant and one price column per requested
region. When a query matches multiple variants or pricing tiers, each is returned with identifying
product, SKU, meter, unit, tier, and reservation term details. A regional cell contains 'n/a' when
no price matches and 'error' when its lookup fails.

API aliases that differ only because one record omits armSkuName are collapsed into one variant.

.PARAMETER Regions
Array of Azure regions. Names can include spaces (for example, 'East US') or use ARM format
(for example, 'eastus'). Region names are trimmed, stripped of whitespace, and lowercased.

.PARAMETER ResourceQueries
Array of hashtables describing the resources to price. Queries can be supplied inline or assigned
to an array first. Standard and ordered hashtables are supported.

Each query supports these fields:
- Name (optional, row label)
- ServiceName
- ProductName
- SkuName
- ArmSkuName
- MeterName
- ServiceFamily
- UnitOfMeasure
- PriceType (default: Consumption)

At least one of ProductName, SkuName, ArmSkuName, or MeterName must be provided for each
query. ServiceName and ServiceFamily can further narrow a query but are too broad on their own.

.PARAMETER CurrencyCode
ISO currency code returned by the retail price API. Default is USD.

.PARAMETER OutputPath
Optional CSV export path.

.PARAMETER HideTable
Suppresses console table output.

.EXAMPLE
$queries = @(
    @{ Name = 'Azure SQL GP Gen5 vCore'; ServiceName = 'SQL Database'; ProductName = 'SQL Database Single/Elastic Pool General Purpose - Compute Gen5'; ArmSkuName = 'SQLDB_GP_Compute_Gen5'; MeterName = 'vCore' },
    @{ Name = 'PostgreSQL Flexible Server Ddsv5 vCore'; ServiceName = 'Azure Database for PostgreSQL'; ProductName = 'Azure Database for PostgreSQL Flexible Server General Purpose Ddsv5 Series Compute'; ArmSkuName = 'AzureDB_PostgreSQL_Flexible_Server_General_Purpose_Ddsv5Series_Compute_vCore'; MeterName = 'vCore' },
    @{ Name = 'Databricks Premium Jobs Compute'; ServiceName = 'Azure Databricks'; SkuName = 'Premium Jobs Compute'; MeterName = 'Premium Jobs Compute DBU' },
    @{ Name = 'Blob Storage Hot LRS'; ServiceName = 'Storage'; ProductName = 'Blob Storage'; SkuName = 'Hot LRS'; MeterName = 'Hot LRS Data Stored' },
    @{ Name = 'Cosmos DB Serverless 1M RUs'; ServiceName = 'Azure Cosmos DB'; ProductName = 'Azure Cosmos DB serverless'; SkuName = 'RUs'; MeterName = '1M RUs' }
)

$regions = @('East US', 'West Europe', 'Sweden Central')

.\Get-AzServiceRegionPricing.ps1 -Regions $regions -ResourceQueries $queries
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Regions,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [System.Collections.IDictionary[]]$ResourceQueries,

    [ValidateNotNullOrEmpty()]
    [string]$CurrencyCode = 'USD',

    [string]$OutputPath,

    [switch]$HideTable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ODataLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value.Replace("'", "''")
}

function Get-QueryField {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Query,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    # IDictionary implementations do not all use the same key comparer.
    $value = $null
    if ($Query.Contains($FieldName)) {
        $value = [string]$Query[$FieldName]
    }
    else {
        $matchedKey = $Query.Keys | Where-Object { [string]$_ -ieq $FieldName } | Select-Object -First 1
        if ($null -ne $matchedKey) {
            $value = [string]$Query[$matchedKey]
        }
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value.Trim()
}

function New-RegionMap {
    param([Parameter(Mandatory = $true)][string[]]$RegionInputs)

    $regionMap = @{}

    foreach ($regionInput in $RegionInputs) {
        $trimmed = $regionInput.Trim()
        # Preserve the supplied name for the output column and normalize only the API value.
        $regionMap[$trimmed] = ($trimmed -replace '\s+', '').ToLowerInvariant()
    }

    return $regionMap
}

function Test-IsCurrentPrice {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][datetime]$CurrentDate
    )

    if ([datetime]$Item.effectiveStartDate -gt $CurrentDate) {
        return $false
    }

    if ($Item.PSObject.Properties['effectiveEndDate'] -and $null -ne $Item.effectiveEndDate -and
        [datetime]$Item.effectiveEndDate -lt $CurrentDate) {
        return $false
    }

    return $true
}

function New-ODataFilter {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Query,
        [Parameter(Mandatory = $true)][string]$ArmRegionName
    )

    $priceType = Get-QueryField -Query $Query -FieldName 'PriceType'
    if ([string]::IsNullOrWhiteSpace($priceType)) {
        $priceType = 'Consumption'
    }

    $escapedRegionName = ConvertTo-ODataLiteral -Value $ArmRegionName
    $escapedPriceType = ConvertTo-ODataLiteral -Value $priceType

    $clauses = [System.Collections.Generic.List[string]]::new()
    $clauses.Add("armRegionName eq '$escapedRegionName'")
    $clauses.Add("priceType eq '$escapedPriceType'")

    $odataExactFields = @(
        @{ QueryField = 'ServiceName'; ApiField = 'serviceName' },
        @{ QueryField = 'ProductName'; ApiField = 'productName' },
        @{ QueryField = 'SkuName'; ApiField = 'skuName' },
        @{ QueryField = 'ArmSkuName'; ApiField = 'armSkuName' },
        @{ QueryField = 'MeterName'; ApiField = 'meterName' },
        @{ QueryField = 'ServiceFamily'; ApiField = 'serviceFamily' }
    )

    foreach ($field in $odataExactFields) {
        $value = Get-QueryField -Query $Query -FieldName $field.QueryField
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $escaped = ConvertTo-ODataLiteral -Value $value
        $clauses.Add("$($field.ApiField) eq '$escaped'")
    }

    return ($clauses -join ' and ')
}

function Get-AzRetailPriceItems {
    param(
        [Parameter(Mandatory = $true)][string]$Filter,
        [Parameter(Mandatory = $true)][string]$Currency
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $requestParameters = @{
        Method      = 'Get'
        Uri         = 'https://prices.azure.com/api/retail/prices'
        Body        = @{
            'api-version' = '2023-01-01-preview'
            '$filter'     = $Filter
            currencyCode = "'$Currency'"
        }
        ErrorAction = 'Stop'
    }

    do {
        $response = Invoke-RestMethod @requestParameters

        foreach ($item in $response.Items) {
            $items.Add($item)
        }

        $requestParameters = @{
            Method      = 'Get'
            Uri         = $response.NextPageLink
            ErrorAction = 'Stop'
        }
    } while (-not [string]::IsNullOrWhiteSpace($response.NextPageLink))

    return $items
}

function Get-QueryLabel {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Query)

    $name = Get-QueryField -Query $Query -FieldName 'Name'
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        return $name
    }

    $parts = @()
    foreach ($fieldName in @('ServiceName', 'ProductName', 'SkuName', 'ArmSkuName', 'MeterName')) {
        $v = Get-QueryField -Query $Query -FieldName $fieldName
        if (-not [string]::IsNullOrWhiteSpace($v)) {
            $parts += $v
        }
    }

    return ($parts -join ' | ')
}

function Get-PriceVariantKey {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [switch]$IgnoreArmSkuName
    )

    # Region is deliberately excluded so equivalent regional records populate one pivoted row.
    # The unit-separator character cannot be confused with punctuation in Azure display names.
    $identityFields = @(
        'serviceName'
        'productName'
        'skuName'
        'armSkuName'
        'meterName'
        'serviceFamily'
        'unitOfMeasure'
        'tierMinimumUnits'
        'type'
        'reservationTerm'
    )

    return ($identityFields | ForEach-Object {
        if ($IgnoreArmSkuName -and $_ -eq 'armSkuName') {
            return ''
        }

        $property = $Item.PSObject.Properties[$_]
        if ($null -eq $property) { '' } else { [string]$property.Value }
    }) -join "`u{001F}"
}

$normalizedRegions = @($Regions | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_)) {
        throw 'Regions cannot contain null, empty, or whitespace-only values.'
    }

    $_.Trim()
})

if (@($normalizedRegions | Sort-Object -Unique).Count -ne $normalizedRegions.Count) {
    throw 'Regions must not contain duplicate values.'
}

$CurrencyCode = $CurrencyCode.Trim().ToUpperInvariant()
if ($CurrencyCode -notmatch '^[A-Z]{3}$') {
    throw 'CurrencyCode must be a three-letter ISO currency code.'
}

# Require a product, SKU, or meter field so queries cannot retrieve an entire service catalog.
for ($i = 0; $i -lt $ResourceQueries.Count; $i++) {
    $query = $ResourceQueries[$i]
    $hasSelectiveField = $false

    foreach ($fieldName in @('ProductName', 'SkuName', 'ArmSkuName', 'MeterName')) {
        $fieldValue = Get-QueryField -Query $query -FieldName $fieldName
        if (-not [string]::IsNullOrWhiteSpace($fieldValue)) {
            $hasSelectiveField = $true
            break
        }
    }

    if (-not $hasSelectiveField) {
        throw "ResourceQueries[$i] must include at least one selective field: ProductName, SkuName, ArmSkuName, or MeterName."
    }
}

$regionMap = New-RegionMap -RegionInputs $normalizedRegions
$duplicateRegionCodes = @($regionMap.Values | Group-Object | Where-Object Count -gt 1)
if ($duplicateRegionCodes.Count -gt 0) {
    throw "Regions resolve to duplicate ARM region codes: $($duplicateRegionCodes.Name -join ', ')."
}

$currentDate = [datetime]::UtcNow
# Reuse identical API responses when multiple resource queries produce the same filter.
$priceItemCache = @{}
$result = foreach ($query in $ResourceQueries) {
    $unitOfMeasureFilter = Get-QueryField -Query $query -FieldName 'UnitOfMeasure'
    $queryName = Get-QueryLabel -Query $query

    # Accumulate one pivoted row per variant while regions are processed independently.
    # Region status supplies the initial n/a value and records lookup failures.
    $rowsByVariant = [ordered]@{}
    $rowKeyByArmSkuAlias = @{}
    $regionStatus = [ordered]@{}

    foreach ($displayRegion in $normalizedRegions) {
        $regionStatus[$displayRegion] = 'n/a'
    }

    foreach ($displayRegion in $normalizedRegions) {
        $regionCode = $regionMap[$displayRegion]

        $odataFilter = New-ODataFilter -Query $query -ArmRegionName $regionCode

        try {
            $cacheKey = "$CurrencyCode`n$odataFilter"
            if (-not $priceItemCache.ContainsKey($cacheKey)) {
                $priceItemCache[$cacheKey] = @(Get-AzRetailPriceItems -Filter $odataFilter -Currency $CurrencyCode)
            }

            $apiItems = $priceItemCache[$cacheKey]

            # UnitOfMeasure is filtered locally because it is not included in the API filter.
            $matched = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $apiItems) {
                $unitMatches = [string]::IsNullOrWhiteSpace($unitOfMeasureFilter) -or
                    [string]$item.unitOfMeasure -ieq $unitOfMeasureFilter

                if ($unitMatches -and (Test-IsCurrentPrice -Item $item -CurrentDate $currentDate)) {
                    $matched.Add($item)
                }
            }

            # The API can expose aliases for one displayed variant. Prefer the eligible record
            # with the latest effective start date, but never choose arbitrarily between prices.
            $matched = @(
                $matched |
                    Group-Object { Get-PriceVariantKey -Item $_ } |
                    ForEach-Object {
                        $newest = @($_.Group | Sort-Object { [datetime]$_.effectiveStartDate } -Descending)
                        $latestDate = [datetime]$newest[0].effectiveStartDate
                        $latest = @($newest | Where-Object { [datetime]$_.effectiveStartDate -eq $latestDate })

                        if (@($latest.retailPrice | Sort-Object -Unique).Count -gt 1) {
                            throw "The API returned conflicting current prices for query '$queryName' in region '$displayRegion'."
                        }

                        $latest[0]
                    }
            )

            # Create each variant row from API metadata once, then fill its regional price columns.
            foreach ($item in $matched) {
                $variantKey = Get-PriceVariantKey -Item $item
                $rowKey = $variantKey

                if (-not $rowsByVariant.Contains($rowKey)) {
                    $aliasKey = Get-PriceVariantKey -Item $item -IgnoreArmSkuName
                    if ($rowKeyByArmSkuAlias.ContainsKey($aliasKey)) {
                        $candidateKey = $rowKeyByArmSkuAlias[$aliasKey]
                        if ($null -ne $candidateKey) {
                            $candidateRow = $rowsByVariant[$candidateKey]
                            $incomingArmSkuName = [string]$item.armSkuName

                            if ([string]::IsNullOrWhiteSpace($incomingArmSkuName) -or
                                [string]::IsNullOrWhiteSpace([string]$candidateRow.ArmSkuName) -or
                                $incomingArmSkuName -eq [string]$candidateRow.ArmSkuName) {
                                $rowKey = $candidateKey
                                if ([string]::IsNullOrWhiteSpace([string]$candidateRow.ArmSkuName)) {
                                    $candidateRow.ArmSkuName = $incomingArmSkuName
                                }
                            }
                        }
                    }
                }

                if (-not $rowsByVariant.Contains($rowKey)) {
                    $row = [ordered]@{
                        QueryName       = $queryName
                        CurrencyCode    = [string]$item.currencyCode
                        ServiceName     = [string]$item.serviceName
                        ProductName     = [string]$item.productName
                        SkuName         = [string]$item.skuName
                        ArmSkuName      = [string]$item.armSkuName
                        MeterName       = [string]$item.meterName
                        ServiceFamily   = [string]$item.serviceFamily
                        UnitOfMeasure   = [string]$item.unitOfMeasure
                        TierMinimumUnits = [decimal]$item.tierMinimumUnits
                        PriceType       = [string]$item.type
                        ReservationTerm = if ($item.PSObject.Properties['reservationTerm']) { [string]$item.reservationTerm } else { $null }
                    }

                    foreach ($region in $normalizedRegions) {
                        $row[$region] = $regionStatus[$region]
                    }

                    $rowsByVariant[$rowKey] = $row
                    $aliasKey = Get-PriceVariantKey -Item $item -IgnoreArmSkuName
                    if (-not $rowKeyByArmSkuAlias.ContainsKey($aliasKey)) {
                        $rowKeyByArmSkuAlias[$aliasKey] = $rowKey
                    }
                    elseif ($null -ne $rowKeyByArmSkuAlias[$aliasKey]) {
                        $existingAliasRow = $rowsByVariant[$rowKeyByArmSkuAlias[$aliasKey]]
                        if (-not [string]::IsNullOrWhiteSpace([string]$existingAliasRow.ArmSkuName) -and
                            -not [string]::IsNullOrWhiteSpace([string]$row.ArmSkuName) -and
                            [string]$existingAliasRow.ArmSkuName -ne [string]$row.ArmSkuName) {
                            $rowKeyByArmSkuAlias[$aliasKey] = $null
                        }
                    }
                }

                $existingPrice = $rowsByVariant[$rowKey][$displayRegion]
                if ($existingPrice -notin @('n/a', 'error') -and
                    [decimal]$existingPrice -ne [decimal]$item.retailPrice) {
                    throw "The API returned conflicting prices for ARM SKU aliases in query '$queryName' in region '$displayRegion'."
                }

                $rowsByVariant[$rowKey][$displayRegion] = [decimal]$item.retailPrice
            }
        }
        catch {
            Write-Warning "Pricing lookup failed for query '$queryName' in region '$displayRegion'. $_"
            $regionStatus[$displayRegion] = 'error'

            foreach ($row in $rowsByVariant.Values) {
                $row[$displayRegion] = 'error'
            }
        }
    }

    if ($rowsByVariant.Count -gt 1) {
        Write-Warning "Query '$queryName' matched $($rowsByVariant.Count) current price variants across the requested regions; emitting one row per variant."
    }

    # When no region produced a price, preserve the query as one result row with n/a or error cells.
    if ($rowsByVariant.Count -eq 0) {
        $row = [ordered]@{
            QueryName       = $queryName
            CurrencyCode    = $CurrencyCode
            ServiceName     = Get-QueryField -Query $query -FieldName 'ServiceName'
            ProductName     = Get-QueryField -Query $query -FieldName 'ProductName'
            SkuName         = Get-QueryField -Query $query -FieldName 'SkuName'
            ArmSkuName      = Get-QueryField -Query $query -FieldName 'ArmSkuName'
            MeterName       = Get-QueryField -Query $query -FieldName 'MeterName'
            ServiceFamily   = Get-QueryField -Query $query -FieldName 'ServiceFamily'
            UnitOfMeasure   = $unitOfMeasureFilter
            TierMinimumUnits = $null
            PriceType       = Get-QueryField -Query $query -FieldName 'PriceType'
            ReservationTerm = $null
        }

        foreach ($region in $normalizedRegions) {
            $row[$region] = $regionStatus[$region]
        }

        [PSCustomObject]$row
    }
    else {
        # Return completed pivot rows after every requested region has been processed.
        foreach ($row in $rowsByVariant.Values) {
            [PSCustomObject]$row
        }
    }
}

if (-not $HideTable) {
    $result | Format-Table -AutoSize | Out-Host
}

if ($OutputPath) {
    $result | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
}
