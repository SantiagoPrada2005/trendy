param(
    [switch]$OmitirImagenes = $false,
    [int]$MaxHilosImagenes = 24
)

$ErrorActionPreference = "Stop"

$csharpCode = @"
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public class ImageDownloadJob
{
    public string Url { get; set; }
    public List<string> TargetPaths { get; set; }
    public ImageDownloadJob()
    {
        TargetPaths = new List<string>();
    }
}

public static class MarketScannerHttp
{
    private static readonly HttpClient client;

    static MarketScannerHttp()
    {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        ServicePointManager.DefaultConnectionLimit = 100;
        var handler = new HttpClientHandler
        {
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        };
        client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(45)
        };
        client.DefaultRequestHeaders.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36");
    }

    public static string GetUtf8String(string url)
    {
        for (int attempt = 1; attempt <= 3; attempt++)
        {
            try
            {
                var bytes = client.GetByteArrayAsync(url).GetAwaiter().GetResult();
                return Encoding.UTF8.GetString(bytes);
            }
            catch (Exception)
            {
                if (attempt == 3) throw;
                Thread.Sleep(1000 * attempt);
            }
        }
        return "";
    }

    public static void DownloadFile(string url, string destinationPath)
    {
        for (int attempt = 1; attempt <= 3; attempt++)
        {
            try
            {
                var bytes = client.GetByteArrayAsync(url).GetAwaiter().GetResult();
                string dir = Path.GetDirectoryName(destinationPath);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                File.WriteAllBytes(destinationPath, bytes);
                return;
            }
            catch (Exception)
            {
                if (attempt == 3) throw;
                Thread.Sleep(1000 * attempt);
            }
        }
    }

    public static void DownloadImagesParallel(List<ImageDownloadJob> jobs, int maxConcurrency = 24)
    {
        int total = jobs.Count;
        int completed = 0;
        int downloaded = 0;
        int skipped = 0;
        int failed = 0;

        Console.WriteLine(string.Format("[IMAGENES] Iniciando verificacion/descarga paralela de {0} imagenes unicas ({1} hilos)...", total, maxConcurrency));

        var options = new ParallelOptions { MaxDegreeOfParallelism = maxConcurrency };
        Parallel.ForEach(jobs, options, job =>
        {
            try
            {
                bool allExist = true;
                string existingSource = null;
                foreach (var p in job.TargetPaths)
                {
                    if (File.Exists(p) && new FileInfo(p).Length > 0)
                    {
                        if (existingSource == null) existingSource = p;
                    }
                    else
                    {
                        allExist = false;
                    }
                }

                if (allExist)
                {
                    Interlocked.Increment(ref skipped);
                }
                else if (existingSource != null)
                {
                    byte[] existingBytes = File.ReadAllBytes(existingSource);
                    foreach (var targetPath in job.TargetPaths)
                    {
                        if (!File.Exists(targetPath) || new FileInfo(targetPath).Length == 0)
                        {
                            string dir = Path.GetDirectoryName(targetPath);
                            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                            File.WriteAllBytes(targetPath, existingBytes);
                        }
                    }
                    Interlocked.Increment(ref skipped);
                }
                else
                {
                    byte[] bytes = null;
                    for (int attempt = 1; attempt <= 3; attempt++)
                    {
                        try
                        {
                            bytes = client.GetByteArrayAsync(job.Url).GetAwaiter().GetResult();
                            break;
                        }
                        catch
                        {
                            Thread.Sleep(500 * attempt);
                        }
                    }

                    if (bytes != null && bytes.Length > 0)
                    {
                        foreach (var targetPath in job.TargetPaths)
                        {
                            string dir = Path.GetDirectoryName(targetPath);
                            if (!Directory.Exists(dir))
                            {
                                Directory.CreateDirectory(dir);
                            }
                            File.WriteAllBytes(targetPath, bytes);
                        }
                        Interlocked.Increment(ref downloaded);
                    }
                    else
                    {
                        Interlocked.Increment(ref failed);
                    }
                }
            }
            catch
            {
                Interlocked.Increment(ref failed);
            }

            int curr = Interlocked.Increment(ref completed);
            if (curr % 150 == 0 || curr == total)
            {
                Console.WriteLine(string.Format("[IMAGENES] Progreso: {0}/{1} (Nuevas descargadas: {2}, Ya en disco: {3}, Fallidas: {4})",
                    curr, total, downloaded, skipped, failed));
            }
        });
    }
}
"@

Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies "System.Net.Http", "System.Core", "System.Xml"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$baseDir = $PSScriptRoot
if (-not $baseDir) { $baseDir = "c:\Users\Usuario\Documents\trendy" }
$dataDir = Join-Path $baseDir "datos"
$histDir = Join-Path $dataDir "historico"
$imagesTrendyDir = Join-Path $baseDir "imagenes"
$imagesBloomDir = Join-Path $baseDir "imagenes_bloomshell"

New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
New-Item -ItemType Directory -Force -Path $histDir | Out-Null
New-Item -ItemType Directory -Force -Path $imagesTrendyDir | Out-Null
New-Item -ItemType Directory -Force -Path $imagesBloomDir | Out-Null

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$scanTimestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
$scanId = (Get-Date).ToString("yyyy-MM-dd_HHmm")

# ==============================================================================
# 0. PRESERVAR SNAPSHOT BASE PREVIO SI EXISTE (PARA COMPARACION HISTORICA REAL)
# ==============================================================================
$prevSnapshotMap = @{}
$prevScanDate = ""

$existingSnapshots = @(Get-ChildItem -Path $histDir -Filter "snapshot_*.json" -ErrorAction SilentlyContinue | Sort-Object Name)
$legacyStructuredPath = Join-Path $dataDir "productos_estructurados.json"

if ($existingSnapshots.Count -eq 0 -and (Test-Path $legacyStructuredPath)) {
    Write-Host "[HISTORICO] Creando snapshot base historico a partir de tu extraccion previa del 19/10/2026..."
    try {
        $legacyFileInfo = Get-Item $legacyStructuredPath
        $legacyDateStr = $legacyFileInfo.LastWriteTime.ToString("yyyy-MM-dd_HHmm")
        $legacyDateIso = $legacyFileInfo.LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ssK")
        $legacyProds = [System.IO.File]::ReadAllText($legacyStructuredPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $baseSnapItems = New-Object System.Collections.Generic.List[object]
        foreach ($lp in $legacyProds) {
            $key = "TRENDY_$($lp.productId)"
            [void]$baseSnapItems.Add([ordered]@{
                unifiedId   = $key
                supplier    = "Trendy"
                productId   = [string]$lp.productId
                reference   = [string]$lp.reference
                name        = [string]$lp.name
                retailPrice = [double]$lp.minPrice
                totalStock  = [int]$lp.totalStock
                isAvailable = [bool]$lp.isAvailable
            })
        }
        $baseSnapObj = [ordered]@{
            scanId    = $legacyDateStr
            timestamp = $legacyDateIso
            note      = "Snapshot base inicial (Trendy 19 Oct 2026)"
            items     = $baseSnapItems
        }
        $baseSnapPath = Join-Path $histDir "snapshot_${legacyDateStr}_base.json"
        [System.IO.File]::WriteAllText($baseSnapPath, ($baseSnapObj | ConvertTo-Json -Depth 8), $utf8NoBom)
        $existingSnapshots = @(Get-ChildItem -Path $histDir -Filter "snapshot_*.json" | Sort-Object Name)
        Write-Host "   -> Snapshot base guardado: $baseSnapPath ($($baseSnapItems.Count) productos)"
    } catch {
        Write-Warning "No se pudo convertir el snapshot previo: $_"
    }
}

if ($existingSnapshots.Count -gt 0) {
    $chosenSnapFile = $existingSnapshots[0]
    if ($existingSnapshots.Count -ge 2) {
        $chosenSnapFile = $existingSnapshots[-1]
    }
    try {
        $prevSnapObj = [System.IO.File]::ReadAllText($chosenSnapFile.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $prevScanDate = [string]$prevSnapObj.timestamp
        foreach ($it in $prevSnapObj.items) {
            $prevSnapshotMap[[string]$it.unifiedId] = $it
        }
        Write-Host "[HISTORICO] Comparando contra escaneo previo: $($chosenSnapFile.Name) ($($prevSnapshotMap.Count) referencias registradas)"
    } catch {
        Write-Warning "No se pudo leer el snapshot previo: $_"
    }
}

# ==============================================================================
# FUNCIONES AUXILIARES DE LIMPIEZA Y CLASIFICACION
# ==============================================================================
function Remove-Diacritics([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $normalized = $text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $normalized.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

function Strip-Html([string]$html) {
    if ([string]::IsNullOrWhiteSpace($html)) { return "" }
    $txt = $html -replace "<br\s*/?>", " " -replace "</p>", " " -replace "</h\d>", " - " -replace "<[^>]+>", ""
    $txt = [System.Net.WebUtility]::HtmlDecode($txt)
    $txt = $txt -replace "[\r\n\t]+", " " -replace "\s{2,}", " "
    return $txt.Trim()
}

function Sanitize-FileName([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return "sin_nombre" }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $clean = Remove-Diacritics $name
    foreach ($c in $invalid) {
        $clean = $clean.Replace($c, [char]'_')
    }
    $clean = $clean -replace "\s+", "_" -replace "[^a-zA-Z0-9_\-\.]", ""
    if ([string]::IsNullOrWhiteSpace($clean)) { return "item" }
    return $clean.Trim('_')
}

function Get-SpecValue($obj, [string]$propName) {
    if ($null -eq $obj) { return "" }
    $prop = $obj.PSObject.Properties[$propName]
    if ($null -ne $prop -and $null -ne $prop.Value) {
        if ($prop.Value -is [System.Array] -or ($prop.Value -is [System.Collections.IEnumerable] -and -not ($prop.Value -is [string]))) {
            return (($prop.Value | ForEach-Object { [string]$_ }) -join " | ") -replace "[\r\n]+", " "
        }
        return ([string]$prop.Value) -replace "[\r\n]+", " "
    }
    return ""
}

function Parse-MinQty([string]$text, [int]$defaultVal = 1) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $defaultVal }
    $m = [regex]::Match($text, '(\d+)')
    if ($m.Success) {
        $v = [int]$m.Groups[1].Value
        if ($v -gt 0 -and $v -le 200) { return $v }
    }
    return $defaultVal
}

function Get-UnifiedCategory([string]$name, [string]$rawCat, [string]$rawSub, [string]$desc) {
    $u = (Remove-Diacritics "$name $rawCat $rawSub").ToUpper()

    if ($u -match "CEJA|LAMINATION|BETUN") { return "Ojos y Cejas > Cejas (Laminadores, Lapices y Geles)" }
    if ($u -match "PESTANINA|MASCARA DE PESTA|PESTANAS|ENCRESPADOR") { return "Ojos y Cejas > Pestaninas, Pestanas y Encrespadores" }
    if ($u -match "DELINEADOR|EYELINER|PLUMON") { return "Ojos y Cejas > Delineadores" }
    if ($u -match "SOMBRA|PALETA DE SOMBRAS") { return "Ojos y Cejas > Sombras y Paletas" }

    if ($u -match "CORRECTOR|CONCEALER") { return "Rostro > Correctores" }
    if ($u -match "BASE|BB CREAM|FOUNDATION") { return "Rostro > Bases de Maquillaje" }
    if ($u -match "POLVO|POWDER|TRASLUCIDO|BANANA") { return "Rostro > Polvos Sueltos y Compactos" }
    if ($u -match "FIJADOR|FIX|PRIMER|PREBASE|SELLANTE|OIL CONTROL") { return "Rostro > Primers, Fijadores y Control Grasa" }
    if ($u -match "RUBOR|BLUSH") { return "Rostro > Rubores (Liquidos, Crema y Polvo)" }
    if ($u -match "ILUMINADOR|HIGHLIGHT|BRONZER|BRONCEADOR|CONTORNO|CONTOUR|DESTELLO") { return "Rostro > Iluminadores, Bronzers y Contorno" }

    if ($u -match "TINTA|LIP TINT") { return "Labios > Tintas de Labios" }
    if ($u -match "BRILLO|GLOSS|LIP OIL|VOLUMINIZADOR|BALSAMO|HIDRATANTE DE LABIOS|LABIOS|LABIAL") { return "Labios > Brillos, Lip Oils y Labiales" }

    if ($u -match "BORLA|ESPONJA|BEAUTY BLENDER|BLENDER") { return "Accesorios > Esponjas, Beauty Blenders y Borlas" }
    if ($u -match "BROCHA|CEPILLO|MEZCLADOR|PINZA|TIJERA|DEPIL") { return "Accesorios > Brochas y Herramientas" }
    if ($u -match "COSMETIQUERA|ORGANIZADOR|MALETA|BOLSA|CARTERA|ESTUCHE") { return "Accesorios > Cosmetiqueras y Organizadores" }
    if ($u -match "BALACA|HEBILLA|CABELLO|MONA|GANCHO|GORRO") { return "Accesorios > Cabello y Balacas" }

    if ($u -match "CORPORAL|MANTEQUILLA|SPLASH|EXFOLIANTE CORPORAL|LOCION") { return "Skincare > Cuidado Corporal" }
    if ($u -match "SERUM|SUERO|TONICO|DESMAQUILLANTE|MASCARILLA|CONTORNO DE OJOS|FACIAL|SKINCARE|CUIDADO DE LA PIEL|ACNE|JABON|SOLAR|BLOQUEADOR|LIMPIADOR|PARCHE") { return "Skincare > Cuidado Facial y Desmaquillantes" }
    if ($u -match "KIT|COMBO|SET") { return "Kits y Colecciones > Kits Regalo y Combos" }

    return "Otros y Novedades > Accesorios y Varios"
}

# ==============================================================================
# 1. DESCARGAR Y PARSEAR COTIZADOR EXCEL MAYORISTA DE TRENDY
# ==============================================================================
Write-Host "================================================================="
Write-Host "FASE 1: Consultando Cotizador Mayorista Oficial de Trendy..."
Write-Host "================================================================="

$excelByVtexId = @{}
$excelByRef = @{}
$excelByCode = @{}
$trendyCotizadorUrl = "https://b2ctrendy.vteximg.com.br/arquivos/COTIZADOR%207%20DE%20SEPTIEMBRE.zip"

try {
    $mayHtml = [MarketScannerHttp]::GetUtf8String("https://www.maquillajetrendyshop.com/mayoristas")
    $mZip = [regex]::Match($mayHtml, 'https://[^"''\s<>]+COTIZADOR[^"''\s<>]+\.zip', 'IgnoreCase')
    if ($mZip.Success) {
        $rawZipUrl = $mZip.Value
        $trendyCotizadorUrl = $rawZipUrl -replace ' ', '%20'
        Write-Host "   -> URL Cotizador detectada en /mayoristas: $trendyCotizadorUrl"
    }
} catch {
    Write-Warning "   -> Usando URL de respaldo para el Cotizador Mayorista de Trendy."
}

$cotizadorZipPath = Join-Path $dataDir "cotizador_trendy_mayorista.zip"
$cotizadorExtractDir = Join-Path $dataDir "cotizador_trendy_temp"

try {
    [MarketScannerHttp]::DownloadFile($trendyCotizadorUrl, $cotizadorZipPath)
    if (Test-Path $cotizadorExtractDir) { Remove-Item -Recurse -Force $cotizadorExtractDir }
    Expand-Archive -Path $cotizadorZipPath -DestinationPath $cotizadorExtractDir -Force
    $xlsxFile = Get-ChildItem -Path $cotizadorExtractDir -Filter "*.xlsx" -Recurse | Where-Object { $_.Name -notlike "._*" } | Select-Object -First 1

    if ($xlsxFile) {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($xlsxFile.FullName)
        $ssEntry = $zip.GetEntry("xl/sharedStrings.xml")
        $sr = New-Object System.IO.StreamReader($ssEntry.Open())
        [xml]$ssXml = $sr.ReadToEnd(); $sr.Close()
        $strings = @($ssXml.sst.si | ForEach-Object {
            if ($null -ne $_.t) {
                if ($_.t -is [string]) { $_.t } else { $_.t.InnerText }
            } elseif ($_.r) {
                ($_.r | ForEach-Object { if ($_.t -is [string]) { $_.t } else { $_.t.InnerText } }) -join ""
            } else { "" }
        })
        $shEntry = $zip.GetEntry("xl/worksheets/sheet1.xml")
        $sr2 = New-Object System.IO.StreamReader($shEntry.Open())
        [xml]$shXml = $sr2.ReadToEnd(); $sr2.Close()
        $zip.Dispose()

        $codeRegex = New-Object System.Text.RegularExpressions.Regex('\b([A-Z]{1,4}\d{2,5})\b')

        foreach ($r in ($shXml.worksheet.sheetData.row | Select-Object -Skip 2)) {
            $cellMap = @{}
            foreach ($c in $r.c) {
                $col = $c.r -replace '[0-9]',''
                $val = if ($c.t -eq "s") { $strings[[int]$c.v] } else { [string]$c.v }
                $cellMap[$col] = $val
            }
            $nameRef = ($cellMap['A'] + '').Trim()
            $skuRef  = ($cellMap['B'] + '').Trim()
            $vtexId  = ($cellMap['C'] + '').Trim()
            $catEx   = ($cellMap['D'] + '').Trim()
            $emp400  = 0.0; [void][double]::TryParse(($cellMap['F'] + ''), [ref]$emp400)
            $dist1M  = 0.0; [void][double]::TryParse(($cellMap['G'] + ''), [ref]$dist1M)
            $minQtyS = ($cellMap['J'] + '').Trim()

            if ($emp400 -gt 0 -or $dist1M -gt 0) {
                if ($emp400 -le 0) { $emp400 = $dist1M }
                if ($dist1M -le 0) { $dist1M = $emp400 }
                $entryObj = @{
                    name    = $nameRef
                    skuRef  = $skuRef
                    vtexId  = $vtexId
                    emp400  = [math]::Round($emp400, 0)
                    dist1M  = [math]::Round($dist1M, 0)
                    minQty  = $minQtyS
                    cat     = $catEx
                }
                if ($vtexId) { $excelByVtexId[$vtexId] = $entryObj }
                if ($skuRef) { $excelByRef[$skuRef.ToUpper()] = $entryObj }
                foreach ($m in $codeRegex.Matches("$nameRef $skuRef")) {
                    $codeKey = $m.Groups[1].Value.ToUpper()
                    if (-not $excelByCode.ContainsKey($codeKey)) {
                        $excelByCode[$codeKey] = $entryObj
                    }
                }
            }
        }
        Write-Host "   -> Cotizador Excel Trendy procesado: $($excelByVtexId.Count) IDs VTEX y $($excelByCode.Count) codigos de referencia con precios Emprendedor ($400k) y Distribuidor ($1M)."
    }
    if (Test-Path $cotizadorExtractDir) { Remove-Item -Recurse -Force $cotizadorExtractDir -ErrorAction SilentlyContinue }
} catch {
    Write-Warning "   -> No se pudo procesar el Excel mayorista de Trendy: $_"
}

# ==============================================================================
# 2. ESCANEAR CATALOGO Y RANKINGS DE TRENDY (API VTEX)
# ==============================================================================
Write-Host "================================================================="
Write-Host "FASE 2: Escaneando Catalogo y Rankings de Ventas de Trendy (VTEX)..."
Write-Host "================================================================="

$allTrendyProducts = @{}
$trendyTopSaleRankMap = @{}
$trendyScoreRankMap = @{}
$trendyReleaseRankMap = @{}

$rankingQueries = @(
    @{ query = "O=OrderByTopSaleDESC&"; map = $trendyTopSaleRankMap; label = "TopVentas" },
    @{ query = "O=OrderByScoreDESC&"; map = $trendyScoreRankMap; label = "Score" },
    @{ query = "O=OrderByReleaseDateDESC&"; map = $trendyReleaseRankMap; label = "Lanzamiento" },
    @{ query = "O=OrderByNameASC&"; map = $null; label = "Nombre" },
    @{ query = ""; map = $null; label = "General" }
)

try {
    $catTreeJson = [MarketScannerHttp]::GetUtf8String("https://www.maquillajetrendyshop.com/api/catalog_system/pub/category/tree/5")
    [System.IO.File]::WriteAllText((Join-Path $dataDir "categorias_arbol.json"), $catTreeJson, $utf8NoBom)
    $catTree = $catTreeJson | ConvertFrom-Json
    foreach ($rootCat in $catTree) {
        $rankingQueries += @{ query = "fq=C:/$($rootCat.id)/&"; map = $null; label = "Cat_$($rootCat.id)" }
    }
} catch {
    Write-Warning "No se pudo obtener el arbol de categorias de Trendy: $_"
}

foreach ($rq in $rankingQueries) {
    $q = $rq.query
    $rankMap = $rq.map
    $from = 0
    $step = 50
    $rankCounter = 0
    while ($true) {
        $to = $from + $step - 1
        $url = "https://www.maquillajetrendyshop.com/api/catalog_system/pub/products/search?${q}_from=$from&_to=$to"
        $json = [MarketScannerHttp]::GetUtf8String($url)
        if ([string]::IsNullOrWhiteSpace($json)) { break }
        $items = $json | ConvertFrom-Json
        if (-not $items -or $items.Count -eq 0) { break }
        foreach ($p in $items) {
            $rankCounter++
            $idStr = [string]$p.productId
            if (-not $allTrendyProducts.ContainsKey($idStr)) {
                $allTrendyProducts[$idStr] = $p
            }
            if ($null -ne $rankMap -and -not $rankMap.ContainsKey($idStr)) {
                $rankMap[$idStr] = $rankCounter
            }
        }
        if ($items.Count -lt $step) { break }
        $from += $step
        if ($from -ge 2500) { break }
    }
}

try {
    $sitemapXml = [MarketScannerHttp]::GetUtf8String("https://www.maquillajetrendyshop.com/sitemap/product-0.xml")
    $smRegex = New-Object System.Text.RegularExpressions.Regex("<loc>https://www\.maquillajetrendyshop\.com/([^<]+)/p</loc>")
    $matches = $smRegex.Matches($sitemapXml)
    $existingSlugs = @{}
    foreach ($p in $allTrendyProducts.Values) {
        if ($p.linkText) { $existingSlugs[$p.linkText.ToLower()] = $true }
    }
    foreach ($m in $matches) {
        $slug = $m.Groups[1].Value.ToLower()
        if (-not $existingSlugs.ContainsKey($slug)) {
            $url = "https://www.maquillajetrendyshop.com/api/catalog_system/pub/products/search/$slug/p"
            $json = [MarketScannerHttp]::GetUtf8String($url)
            if (-not [string]::IsNullOrWhiteSpace($json) -and $json -ne "[]") {
                $items = $json | ConvertFrom-Json
                foreach ($p in $items) {
                    $idStr = [string]$p.productId
                    if (-not $allTrendyProducts.ContainsKey($idStr)) {
                        $allTrendyProducts[$idStr] = $p
                    }
                }
            }
        }
    }
} catch {
    Write-Warning "No se pudo consultar el sitemap opcional de Trendy: $_"
}

$sortedTrendyProducts = $allTrendyProducts.Values | Sort-Object { [int]$_.productId }
Write-Host "   -> Total productos unicos activos en Trendy: $($sortedTrendyProducts.Count)"

# 2B. CONSULTAR MICROSERVICIO EN VIVO DE PRECIOS MAYORISTAS DE TRENDY (_v/account/getPricingBatch)
$livePricingBySku = @{}
try {
    $allTrendySkus = New-Object System.Collections.Generic.List[string]
    $seenTrendySkus = @{}
    foreach ($tp in $sortedTrendyProducts) {
        if ($tp.items) {
            foreach ($tit in $tp.items) {
                $sIdStr = [string]$tit.itemId
                if ($sIdStr -and -not $seenTrendySkus.ContainsKey($sIdStr)) {
                    $seenTrendySkus[$sIdStr] = $true
                    [void]$allTrendySkus.Add($sIdStr)
                }
            }
        }
    }
    Write-Host "   -> Consultando API en vivo _v/account/getPricingBatch para $($allTrendySkus.Count) SKUs de Trendy..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $vtexBaseHeaders = @{
        "Content-Type"  = "application/json"
        "cache-control" = "no-cache"
        "x-vtex-token"  = "Y7QaCGWGx1GJGACHXoYBcbZ49e45F1dvETgI5DV6ekVohpPocVyQmiwLubA6GBzM"
    }
    $tokResp = Invoke-RestMethod -Uri "https://www.maquillajetrendyshop.com/_v/account/getToken" -Method Get -Headers $vtexBaseHeaders -TimeoutSec 30
    if ($tokResp -and $tokResp.token) {
        $vtexAuthHeaders = @{
            "Content-Type"   = "application/json"
            "cache-control"  = "no-cache"
            "x-vtex-token"   = "Y7QaCGWGx1GJGACHXoYBcbZ49e45F1dvETgI5DV6ekVohpPocVyQmiwLubA6GBzM"
            "x-secure-token" = [string]$tokResp.token
        }
        for ($bIdx = 0; $bIdx -lt $allTrendySkus.Count; $bIdx += 50) {
            $bCnt = [Math]::Min(50, $allTrendySkus.Count - $bIdx)
            $skuBatch = $allTrendySkus.GetRange($bIdx, $bCnt)
            $batchBody = @{ skuIds = $skuBatch } | ConvertTo-Json -Compress
            $batchResp = Invoke-RestMethod -Uri "https://www.maquillajetrendyshop.com/_v/account/getPricingBatch" -Method Post -Headers $vtexAuthHeaders -Body $batchBody -TimeoutSec 30
            if ($batchResp -and $batchResp.prices) {
                foreach ($prop in $batchResp.prices.PSObject.Properties) {
                    $livePricingBySku[$prop.Name] = $prop.Value
                }
            }
        }
        Write-Host "   -> Precios mayoristas en vivo obtenidos exitosamente para $($livePricingBySku.Count) / $($allTrendySkus.Count) SKUs (Emprendedor `$400k, Distribuidor `$1M y PVP)."
    }
} catch {
    Write-Warning "   -> Error parcial consultando _v/account/getPricingBatch: $_"
}

# ==============================================================================
# 3. ESCANEAR CATALOGO MAYORISTA, DETAL Y RANKING DE BLOOMSHELL
# ==============================================================================
Write-Host "================================================================="
Write-Host "FASE 3: Escaneando Catalogo Mayorista y Detal de Bloomshell..."
Write-Host "================================================================="

$bloomBestSellingRankMap = @{}
$bsRank = 0
$bsHandleRegex = New-Object System.Text.RegularExpressions.Regex('/products/([a-z0-9\-]+)')

for ($pg = 1; $pg -le 10; $pg++) {
    try {
        $bsHtml = [MarketScannerHttp]::GetUtf8String("https://bloomshell.co/collections/all?sort_by=best-selling&page=$pg")
        $mHandles = $bsHandleRegex.Matches($bsHtml)
        $newInPage = 0
        foreach ($mh in $mHandles) {
            $h = $mh.Groups[1].Value.ToLower()
            if (-not $bloomBestSellingRankMap.ContainsKey($h)) {
                $bsRank++
                $bloomBestSellingRankMap[$h] = $bsRank
                $newInPage++
            }
        }
        if ($newInPage -eq 0) { break }
    } catch {
        break
    }
}
Write-Host "   -> Ranking Best-Selling de Bloomshell capturado: $($bloomBestSellingRankMap.Count) productos posicionados."

$bloomShopifyByHandle = @{}
try {
    for ($pg = 1; $pg -le 5; $pg++) {
        $pJson = [MarketScannerHttp]::GetUtf8String("https://bloomshell.co/products.json?limit=250&page=$pg")
        if ([string]::IsNullOrWhiteSpace($pJson)) { break }
        $pObj = $pJson | ConvertFrom-Json
        if (-not $pObj.products -or $pObj.products.Count -eq 0) { break }
        foreach ($sp in $pObj.products) {
            $bloomShopifyByHandle[$sp.handle.ToLower()] = $sp
        }
        if ($pObj.products.Count -lt 250) { break }
    }
} catch {
    Write-Warning "Error parcial leyendo /products.json de Bloomshell: $_"
}
Write-Host "   -> Productos enriquecidos desde Shopify API (/products.json): $($bloomShopifyByHandle.Count)"

$bloomWholesaleRows = New-Object System.Collections.Generic.List[object]
$cursor = $null
$pageCount = 0
while ($true) {
    $qoUrl = "https://bloomshell.co/a/wholesale/quick-order-data"
    if ($cursor) {
        $qoUrl += "?cursor=$([uri]::EscapeDataString($cursor))"
    }
    $qoJson = [MarketScannerHttp]::GetUtf8String($qoUrl)
    if ([string]::IsNullOrWhiteSpace($qoJson)) { break }
    $qoObj = $qoJson | ConvertFrom-Json
    $pageCount++
    if ($qoObj.rows) {
        foreach ($row in $qoObj.rows) {
            [void]$bloomWholesaleRows.Add($row)
        }
    }
    if (-not $qoObj.hasNextPage -or -not $qoObj.nextCursor -or $pageCount -ge 20) { break }
    $cursor = [string]$qoObj.nextCursor
}
Write-Host "   -> Productos extraidos del Portal Mayorista Bloomshell (/a/wholesale/quick-order-data): $($bloomWholesaleRows.Count) en $pageCount paginas."

# ==============================================================================
# 4. PROCESAR Y UNIFICAR PRODUCTOS + PREPARAR DESCARGA DE IMAGENES
# ==============================================================================
Write-Host "================================================================="
Write-Host "FASE 4: Procesando Estudio de Mercado, Margenes y Afinidad Valle del Cauca..."
Write-Host "================================================================="

$imageJobsByUrl = @{}
function Register-ImageDownload([string]$rawUrl, [string]$localFileAbs) {
    if ([string]::IsNullOrWhiteSpace($rawUrl)) { return }
    $cleanUrl = ($rawUrl -split "\?")[0]
    if (-not $imageJobsByUrl.ContainsKey($cleanUrl)) {
        $job = New-Object ImageDownloadJob
        $job.Url = $rawUrl
        $imageJobsByUrl[$cleanUrl] = $job
    }
    $existingJob = $imageJobsByUrl[$cleanUrl]
    if (-not $existingJob.TargetPaths.Contains($localFileAbs)) {
        $existingJob.TargetPaths.Add($localFileAbs)
    }
}

$skuRows = New-Object System.Collections.Generic.List[object]
$productRows = New-Object System.Collections.Generic.List[object]
$cleanProductsJsonList = New-Object System.Collections.Generic.List[object]
$unifiedMarketList = New-Object System.Collections.Generic.List[object]
$codeRegexGeneral = New-Object System.Text.RegularExpressions.Regex('\b([A-Z]{1,4}\d{2,5})\b')

# ------------------------------------------------------------------------------
# 4A. Procesar Trendy
# ------------------------------------------------------------------------------
foreach ($p in $sortedTrendyProducts) {
    $prodId = [string]$p.productId
    $prodName = [string]$p.productName
    $prodRef = [string]$p.productReference
    $brand = if ($p.brand) { [string]$p.brand } else { "Trendy" }
    $slug = [string]$p.linkText
    $prodUrl = "https://www.maquillajetrendyshop.com/$slug/p"
    $releaseDate = [string]$p.releaseDate
    $metaDesc = Strip-Html ([string]$p.metaTagDescription)
    $descHtml = [string]$p.description
    $descText = Strip-Html $descHtml

    $cats = @()
    if ($p.categories) {
        $cats = @($p.categories | ForEach-Object { ([string]$_).Trim('/') })
    }
    $mainCategoryRoute = if ($cats.Count -gt 0) { $cats[0] } else { "" }
    $catParts = if ($mainCategoryRoute) { $mainCategoryRoute -split "/" } else { @() }
    $catNivel1 = if ($catParts.Count -ge 1) { $catParts[0] } else { "" }
    $catNivel2 = if ($catParts.Count -ge 2) { $catParts[1] } else { "" }
    $catNivel3 = if ($catParts.Count -ge 3) { $catParts[2] } else { "" }

    $clustersList = @()
    if ($p.productClusters) {
        foreach ($prop in $p.productClusters.PSObject.Properties) {
            $clustersList += [string]$prop.Value
        }
    }
    $uniqueClusters = @($clustersList | Select-Object -Unique)
    $clustersStr = $uniqueClusters -join " | "

    $tipoPiel = Get-SpecValue $p "Tipo de piel"
    $acabado = Get-SpecValue $p "Acabado"
    $pumUnidad = Get-SpecValue $p "PUM- Unidad de medida"
    $pumMedida = Get-SpecValue $p "PUM-Medida"
    $formulaCosmetica = ""
    $unidadMinMayorista = ""
    $garantia = ""
    $infoAdicional = ""
    foreach ($prop in $p.PSObject.Properties) {
        if ($prop.Name -like "F*rmula cosm*tica") { $formulaCosmetica = Get-SpecValue $p $prop.Name }
        elseif ($prop.Name -like "Unidad m*nima mayoristas") { $unidadMinMayorista = Get-SpecValue $p $prop.Name }
        elseif ($prop.Name -like "Garant*a") { $garantia = Get-SpecValue $p $prop.Name }
        elseif ($prop.Name -like "Informaci*n adicional") { $infoAdicional = Get-SpecValue $p $prop.Name }
    }
    $ingredientes = Get-SpecValue $p "Ingredientes"
    $cuidados = Get-SpecValue $p "Cuidados"
    $registroInvima = Get-SpecValue $p "Registro Invima"
    $beneficios = Get-SpecValue $p "Beneficios"
    $contenido = Get-SpecValue $p "Contenido"

    $folderSlug = Sanitize-FileName "${prodId}_${slug}"
    $prodImageFolderRel = "imagenes/$folderSlug"
    $prodImageFolderAbs = Join-Path $imagesTrendyDir $folderSlug

    $prodMinPrice = $null
    $prodMaxPrice = $null
    $prodRetailListPrice = $null
    $prodWholesaleTier1 = $null
    $prodWholesaleListPrice = $null
    $prodWholesaleTier2 = $null
    $prodWholesaleSource = "Estimado (~30%)"
    $prodTotalStock = 0
    $prodAllImages = New-Object System.Collections.Generic.List[string]
    $prodAllLocalImages = New-Object System.Collections.Generic.List[string]
    $prodAllVariantNames = New-Object System.Collections.Generic.List[string]
    $cleanSkusList = New-Object System.Collections.Generic.List[object]

    $matchedExcelForMinQty = $null

    $itemsList = @($p.items)
    foreach ($item in $itemsList) {
        $skuId = [string]$item.itemId
        $skuName = [string]$item.name
        $skuNameComplete = [string]$item.nameComplete
        $complementName = Strip-Html ([string]$item.complementName)
        $ean = [string]$item.ean
        $refIdVal = ""
        if ($item.referenceId -and $item.referenceId.Count -gt 0) {
            $refIdVal = [string]$item.referenceId[0].Value
        }

        $skuExcel = $null
        if ($excelByVtexId.ContainsKey($skuId)) {
            $skuExcel = $excelByVtexId[$skuId]
        } elseif ($refIdVal -and $excelByRef.ContainsKey($refIdVal.ToUpper())) {
            $skuExcel = $excelByRef[$refIdVal.ToUpper()]
        }
        if (-not $matchedExcelForMinQty -and $skuExcel) {
            $matchedExcelForMinQty = $skuExcel
        }

        $measureUnit = [string]$item.measurementUnit
        $unitMult = $item.unitMultiplier

        $colorVal = Get-SpecValue $item "Color"
        $tonoVal = Get-SpecValue $item "Tono"
        $otherVarList = @()
        if ($item.variations) {
            foreach ($vName in $item.variations) {
                $vStr = [string]$vName
                $vVal = Get-SpecValue $item $vStr
                $otherVarList += "${vStr}: ${vVal}"
            }
        }
        $variationsSummary = $otherVarList -join " | "
        if ($colorVal) { [void]$prodAllVariantNames.Add($colorVal) }
        elseif ($tonoVal) { [void]$prodAllVariantNames.Add($tonoVal) }
        else { [void]$prodAllVariantNames.Add($skuName) }

        $price = 0.0
        $listPrice = 0.0
        $priceWithoutDiscount = 0.0
        $stock = 0
        $isAvailable = $false

        if ($item.sellers -and $item.sellers.Count -gt 0) {
            $seller = $item.sellers[0]
            $offer = $seller.commertialOffer
            if ($offer) {
                $price = [double]$offer.Price
                $listPrice = [double]$offer.ListPrice
                $priceWithoutDiscount = [double]$offer.PriceWithoutDiscount
                $stock = [int]$offer.AvailableQuantity
                $isAvailable = [bool]$offer.IsAvailable
            }
        }

        $skuEmpPrice = 0.0
        $skuEmpListPrice = 0.0
        $skuDistPrice = 0.0
        $skuSource = ""

        if ($livePricingBySku.ContainsKey($skuId)) {
            $liveEntry = $livePricingBySku[$skuId]
            if ($liveEntry -and $liveEntry.fixedPrices) {
                $fpList = @($liveEntry.fixedPrices)
                $pvpEntry = $fpList | Where-Object { ([string]$_.tradePolicyId).Trim().ToLower() -eq "1" -and $_.minQuantity -eq 1 } | Select-Object -First 1
                if (-not $pvpEntry) { $pvpEntry = $fpList | Where-Object { ([string]$_.tradePolicyId).Trim().ToLower() -eq "1" } | Select-Object -First 1 }
                if ($pvpEntry -and [double]$pvpEntry.value -gt 0) {
                    if ($price -le 0) {
                        $price = [double]$pvpEntry.value
                        $listPrice = if ($pvpEntry.listPrice -and [double]$pvpEntry.listPrice -gt $price) { [double]$pvpEntry.listPrice } else { $price }
                    } elseif ($listPrice -le 0 -and $pvpEntry.listPrice -and [double]$pvpEntry.listPrice -gt $price) {
                        $listPrice = [double]$pvpEntry.listPrice
                    }
                } elseif ($price -le 0 -and $liveEntry.basePrice -and [double]$liveEntry.basePrice -gt 0) {
                    $price = [double]$liveEntry.basePrice
                    $listPrice = $price
                }

                $empEntry = $fpList | Where-Object { ([string]$_.tradePolicyId).Trim().ToLower() -eq "emprendedor" -and $_.minQuantity -eq 1 } | Select-Object -First 1
                if (-not $empEntry) { $empEntry = $fpList | Where-Object { ([string]$_.tradePolicyId).Trim().ToLower() -eq "emprendedor" } | Select-Object -First 1 }
                if ($empEntry -and [double]$empEntry.value -gt 0) {
                    $skuEmpPrice = [double]$empEntry.value
                    $skuEmpListPrice = if ($empEntry.listPrice -and [double]$empEntry.listPrice -gt $skuEmpPrice) { [double]$empEntry.listPrice } else { $skuEmpPrice }
                    $skuSource = "API Cotizador en Vivo Trendy"
                }

                $distEntry = $fpList | Where-Object { ([string]$_.tradePolicyId).Trim().ToLower() -in @("distribuidor", "3", "trendyb2b") -and $_.minQuantity -eq 1 } | Select-Object -First 1
                if (-not $distEntry) { $distEntry = $fpList | Where-Object { ([string]$_.tradePolicyId).Trim().ToLower() -in @("distribuidor", "3", "trendyb2b") } | Select-Object -First 1 }
                if ($distEntry -and [double]$distEntry.value -gt 0) {
                    $skuDistPrice = [double]$distEntry.value
                }
            }
        }

        if ($skuEmpPrice -le 0 -and $skuExcel -and $skuExcel.emp400 -gt 0) {
            $skuEmpPrice = [double]$skuExcel.emp400
            $skuEmpListPrice = $skuEmpPrice
            $skuDistPrice = [double]$skuExcel.dist1M
            $skuSource = "Cotizador Excel Trendy (SKU Exacto)"
        }
        if ($skuEmpPrice -le 0 -and $price -gt 0) {
            $skuEmpPrice = [math]::Round(($price * 0.70) / 100) * 100
            $skuEmpListPrice = $skuEmpPrice
            $skuDistPrice = [math]::Round(($price * 0.64) / 100) * 100
            $skuSource = "Estimado (~30%)"
        }
        if ($skuDistPrice -le 0) { $skuDistPrice = $skuEmpPrice }
        if ($skuEmpListPrice -le 0) { $skuEmpListPrice = $skuEmpPrice }

        $discountPct = 0.0
        if ($listPrice -gt 0 -and $price -lt $listPrice) {
            $discountPct = [math]::Round((($listPrice - $price) / $listPrice) * 100, 2)
        }

        if ($price -gt 0) {
            if ($null -eq $prodMinPrice -or $price -lt $prodMinPrice) {
                $prodMinPrice = $price
                $prodRetailListPrice = if ($listPrice -gt $price) { $listPrice } else { $price }
            }
            if ($null -eq $prodMaxPrice -or $price -gt $prodMaxPrice) { $prodMaxPrice = $price }
        }
        if ($skuEmpPrice -gt 0) {
            if ($null -eq $prodWholesaleTier1 -or $skuEmpPrice -lt $prodWholesaleTier1) {
                $prodWholesaleTier1 = $skuEmpPrice
                $prodWholesaleListPrice = $skuEmpListPrice
                $prodWholesaleTier2 = $skuDistPrice
                if ($skuSource) { $prodWholesaleSource = $skuSource }
            }
        }
        $prodTotalStock += $stock

        $skuGalleryUrls = New-Object System.Collections.Generic.List[string]
        $skuLocalFiles = New-Object System.Collections.Generic.List[string]
        $pickerUrl = ""

        if ($item.images) {
            foreach ($img in $item.images) {
                $rawUrl = [string]$img.imageUrl
                if ([string]::IsNullOrWhiteSpace($rawUrl)) { continue }
                $cleanUrl = ($rawUrl -split "\?")[0]
                $imgId = [string]$img.imageId
                $label = [string]$img.imageLabel

                if ($label -eq "Picker") {
                    $pickerUrl = $cleanUrl
                } else {
                    [void]$skuGalleryUrls.Add($cleanUrl)
                }
                if (-not $prodAllImages.Contains($cleanUrl)) {
                    [void]$prodAllImages.Add($cleanUrl)
                }

                $uriObj = [System.Uri]$cleanUrl
                $origFileName = [System.IO.Path]::GetFileName($uriObj.LocalPath)
                $safeOrigName = Sanitize-FileName $origFileName
                if (-not $safeOrigName.Contains(".")) { $safeOrigName += ".jpg" }
                $localFileName = "${imgId}_${safeOrigName}"
                $localFileAbs = Join-Path $prodImageFolderAbs $localFileName
                $localFileRel = "$prodImageFolderRel/$localFileName"
                if (-not $skuLocalFiles.Contains($localFileRel)) {
                    [void]$skuLocalFiles.Add($localFileRel)
                }
                if (-not $prodAllLocalImages.Contains($localFileRel)) {
                    [void]$prodAllLocalImages.Add($localFileRel)
                }

                Register-ImageDownload $rawUrl $localFileAbs
            }
        }

        $mainImgUrl = if ($skuGalleryUrls.Count -gt 0) { $skuGalleryUrls[0] } else { "" }

        $skuRow = [ordered]@{
            Producto_ID               = $prodId
            SKU_ID                    = $skuId
            Referencia_Producto       = $prodRef
            Referencia_SKU            = $refIdVal
            Nombre_SKU                = $skuName
            Nombre_Producto           = $prodName
            Nombre_Completo           = $skuNameComplete
            Marca                     = $brand
            Categoria_Principal       = $catNivel1
            Subcategoria_Nivel_2      = $catNivel2
            Subcategoria_Nivel_3      = $catNivel3
            Ruta_Categorias           = $mainCategoryRoute
            Color                     = $colorVal
            Tono                      = $tonoVal
            Variaciones               = $variationsSummary
            Precio_Venta_COP          = $price
            Precio_Lista_COP          = $listPrice
            Precio_Sin_Descuento_COP  = $priceWithoutDiscount
            Precio_Mayorista_400k_COP = $skuEmpPrice
            Precio_Mayorista_1M_COP   = $skuDistPrice
            Descuento_Porcentaje      = $discountPct
            Disponible                = if ($isAvailable) { "SI" } else { "NO" }
            Stock_Disponible          = $stock
            Unidad_Minima_Mayoristas  = $unidadMinMayorista
            Contenido                 = $contenido
            PUM_Unidad                = $pumUnidad
            PUM_Medida                = $pumMedida
            Registro_Invima           = $registroInvima
            Tipo_De_Piel              = $tipoPiel
            Acabado                   = $acabado
            Formula_Cosmetica         = $formulaCosmetica
            Beneficios                = $beneficios
            Ingredientes              = $ingredientes
            Cuidados                  = $cuidados
            Garantia                  = $garantia
            Informacion_Adicional     = $infoAdicional
            Etiquetas_Clusters        = $clustersStr
            EAN                       = $ean
            Unidad_Medida_Venta       = $measureUnit
            Multiplicador_Unidad      = $unitMult
            Fecha_Lanzamiento         = $releaseDate
            Resumen_Corto             = $complementName
            Meta_Descripcion          = $metaDesc
            Descripcion_Texto         = $descText
            URL_Producto              = $prodUrl
            Imagen_Principal_URL      = $mainImgUrl
            Imagenes_Galeria_URLs     = ($skuGalleryUrls -join " | ")
            Imagen_Selector_Color_URL = $pickerUrl
            Carpeta_Imagenes_Local    = $prodImageFolderRel
            Archivos_Imagenes_Local   = ($skuLocalFiles -join " | ")
        }
        [void]$skuRows.Add((New-Object PSObject -Property $skuRow))

        $cleanSkuObj = [ordered]@{
            skuId                = $skuId
            reference            = $refIdVal
            name                 = $skuName
            nameComplete         = $skuNameComplete
            ean                  = $ean
            color                = $colorVal
            tono                 = $tonoVal
            variations           = $variationsSummary
            price                = $price
            listPrice            = $listPrice
            wholesaleTier1       = $skuEmpPrice
            wholesaleListPrice   = $skuEmpListPrice
            wholesaleTier2       = $skuDistPrice
            discountPercent      = $discountPct
            isAvailable          = $isAvailable
            stock                = $stock
            mainImageUrl         = $mainImgUrl
            galleryImageUrls     = $skuGalleryUrls
            pickerImageUrl       = $pickerUrl
            localImages          = $skuLocalFiles
        }
        [void]$cleanSkusList.Add($cleanSkuObj)
    }

    if ($null -eq $prodMinPrice) { $prodMinPrice = 0 }
    if ($null -eq $prodMaxPrice) { $prodMaxPrice = 0 }
    if ($null -eq $prodRetailListPrice) { $prodRetailListPrice = $prodMinPrice }
    if ($null -eq $prodWholesaleTier1) { $prodWholesaleTier1 = [math]::Round(($prodMinPrice * 0.70) / 100) * 100 }
    if ($null -eq $prodWholesaleListPrice) { $prodWholesaleListPrice = $prodWholesaleTier1 }
    if ($null -eq $prodWholesaleTier2) { $prodWholesaleTier2 = [math]::Round(($prodMinPrice * 0.64) / 100) * 100 }
    $prodMainImg = if ($prodAllImages.Count -gt 0) { $prodAllImages[0] } else { "" }

    $prodRow = [ordered]@{
        Producto_ID               = $prodId
        Referencia_Producto       = $prodRef
        Nombre_Producto           = $prodName
        Marca                     = $brand
        Categoria_Principal       = $catNivel1
        Subcategoria_Nivel_2      = $catNivel2
        Subcategoria_Nivel_3      = $catNivel3
        Ruta_Categorias           = $mainCategoryRoute
        Cantidad_Variantes_SKUs   = $itemsList.Count
        Variantes_Tonos           = (($prodAllVariantNames | Select-Object -Unique) -join " | ")
        Precio_Minimo_COP         = $prodMinPrice
        Precio_Maximo_COP         = $prodMaxPrice
        Precio_Mayorista_400k_COP = $prodWholesaleTier1
        Precio_Mayorista_1M_COP   = $prodWholesaleTier2
        Tiene_Stock_Disponible    = if ($prodTotalStock -gt 0) { "SI" } else { "NO" }
        Stock_Total_Acumulado     = $prodTotalStock
        Unidad_Minima_Mayoristas  = $unidadMinMayorista
        Contenido                 = $contenido
        PUM_Unidad                = $pumUnidad
        PUM_Medida                = $pumMedida
        Registro_Invima           = $registroInvima
        Tipo_De_Piel              = $tipoPiel
        Acabado                   = $acabado
        Formula_Cosmetica         = $formulaCosmetica
        Beneficios                = $beneficios
        Ingredientes              = $ingredientes
        Cuidados                  = $cuidados
        Garantia                  = $garantia
        Informacion_Adicional     = $infoAdicional
        Etiquetas_Clusters        = $clustersStr
        Fecha_Lanzamiento         = $releaseDate
        Meta_Descripcion          = $metaDesc
        Descripcion_Texto         = $descText
        URL_Producto              = $prodUrl
        Imagen_Principal_URL      = $prodMainImg
        Todas_Las_Imagenes_URLs   = ($prodAllImages -join " | ")
        Carpeta_Imagenes_Local    = $prodImageFolderRel
    }
    [void]$productRows.Add((New-Object PSObject -Property $prodRow))

    $cleanProdObj = [ordered]@{
        productId            = $prodId
        reference            = $prodRef
        name                 = $prodName
        brand                = $brand
        slug                 = $slug
        url                  = $prodUrl
        releaseDate          = $releaseDate
        categoryMain         = $catNivel1
        subcategory2         = $catNivel2
        subcategory3         = $catNivel3
        categories           = $cats
        clusters             = $uniqueClusters
        minPrice             = $prodMinPrice
        maxPrice             = $prodMaxPrice
        retailListPrice      = $prodRetailListPrice
        wholesalePrice400k   = $prodWholesaleTier1
        wholesaleListPrice   = $prodWholesaleListPrice
        wholesalePrice1M     = $prodWholesaleTier2
        totalStock           = $prodTotalStock
        isAvailable          = ($prodTotalStock -gt 0)
        specifications       = [ordered]@{
            unidadMinimaMayoristas = $unidadMinMayorista
            contenido              = $contenido
            pumUnidad              = $pumUnidad
            pumMedida              = $pumMedida
            registroInvima         = $registroInvima
            tipoDePiel             = $tipoPiel
            acabado                = $acabado
            formulaCosmetica       = $formulaCosmetica
            beneficios             = $beneficios
            ingredientes           = $ingredientes
            cuidados               = $cuidados
            garantia               = $garantia
            informacionAdicional   = $infoAdicional
        }
        metaDescription      = $metaDesc
        descriptionText      = $descText
        descriptionHtml      = $descHtml
        imageFolderLocal     = $prodImageFolderRel
        variantsCount        = $cleanSkusList.Count
        variants             = $cleanSkusList
    }
    [void]$cleanProductsJsonList.Add($cleanProdObj)

    $wholesaleTier1 = [double]$prodWholesaleTier1
    $wholesaleTier2 = [double]$prodWholesaleTier2
    $wholesaleSource = $prodWholesaleSource
    $minQtyText = $unidadMinMayorista
    if (-not $minQtyText -and $matchedExcelForMinQty -and $matchedExcelForMinQty.minQty) {
        $minQtyText = $matchedExcelForMinQty.minQty
    }

    $minWholesaleQty = Parse-MinQty $minQtyText 2
    $topSaleRank = if ($trendyTopSaleRankMap.ContainsKey($prodId)) { [int]$trendyTopSaleRankMap[$prodId] } else { 999 }
    $scoreRank = if ($trendyScoreRankMap.ContainsKey($prodId)) { [int]$trendyScoreRankMap[$prodId] } else { 999 }
    $unifiedCat = Get-UnifiedCategory $prodName $catNivel1 $catNivel2 $descText

    [void]$unifiedMarketList.Add([ordered]@{
        unifiedId            = "TRENDY_$prodId"
        supplier             = "Trendy"
        productId            = $prodId
        reference            = $prodRef
        name                 = $prodName
        brand                = $brand
        slug                 = $slug
        url                  = $prodUrl
        releaseDate          = if ($releaseDate) { ($releaseDate -split "T")[0] } else { "" }
        unifiedCategory      = $unifiedCat
        categoryMain         = if ($catNivel1) { $catNivel1 } else { "Maquillaje" }
        subcategory          = $catNivel2
        clusters             = $uniqueClusters
        retailPrice          = [double]$prodMinPrice
        retailMaxPrice       = [double]$prodMaxPrice
        retailListPrice      = [double]$prodRetailListPrice
        wholesaleTier1       = [double]$wholesaleTier1
        wholesaleListPrice   = [double]$prodWholesaleListPrice
        wholesaleTier1Label  = "Emprendedor (`$400k)"
        wholesaleTier2       = [double]$wholesaleTier2
        wholesaleTier2Label  = "Distribuidor (`$1M)"
        wholesaleSource      = $wholesaleSource
        minWholesaleQty      = [int]$minWholesaleQty
        minWholesaleQtyText  = if ($minQtyText) { $minQtyText } else { "Min. $minWholesaleQty uds" }
        totalStock           = [int]$prodTotalStock
        isAvailable          = ($prodTotalStock -gt 0)
        topSaleRank          = $topSaleRank
        scoreRank            = $scoreRank
        variantsCount        = $cleanSkusList.Count
        variants             = $cleanSkusList
        allRemoteImages      = $prodAllImages
        allLocalImages       = $prodAllLocalImages
        imageFolderLocal     = $prodImageFolderRel
        descriptionText      = $descText
        specifications       = $cleanProdObj.specifications
    })
}

# ------------------------------------------------------------------------------
# 4B. Procesar Bloomshell (Combinando Portal Mayorista Quick-Order + Shopify API)
# ------------------------------------------------------------------------------
foreach ($row in $bloomWholesaleRows) {
    $handle = ([string]$row.handle).ToLower()
    $rawProdId = ([string]$row.productId) -replace "gid://shopify/Product/", ""
    $title = [string]$row.title
    $vendorRaw = [string]$row.vendor
    $prodUrl = "https://bloomshell.co/products/$handle"

    $shopifyProd = if ($bloomShopifyByHandle.ContainsKey($handle)) { $bloomShopifyByHandle[$handle] } else { $null }
    $publishedAt = if ($shopifyProd -and $shopifyProd.published_at) { [string]$shopifyProd.published_at } elseif ($shopifyProd -and $shopifyProd.created_at) { [string]$shopifyProd.created_at } else { "" }
    $descHtml = if ($shopifyProd -and $shopifyProd.body_html) { [string]$shopifyProd.body_html } else { "" }
    $descText = Strip-Html $descHtml
    if (-not $descText) { $descText = $title }

    $erpBaseCostInfo = ""
    if ($vendorRaw -match '\$\s*([0-9\.,]+)') {
        $erpBaseCostInfo = $vendorRaw
    }

    $colTitles = @()
    if ($row.collections) {
        foreach ($c in $row.collections) {
            if ($c.title) { $colTitles += ([string]$c.title).Trim() }
        }
    }
    $uniqueCols = @($colTitles | Select-Object -Unique)
    $catMain = if ($uniqueCols.Count -gt 0) {
        ($uniqueCols | Where-Object { $_ -notin @("MAQUILLAJE", "Nuevo", "sin categoria", "Sin categorizar") } | Select-Object -First 1)
    } else { "" }
    if (-not $catMain) { $catMain = if ($uniqueCols.Count -gt 0) { $uniqueCols[0] } else { "MAQUILLAJE" } }

    $folderSlug = Sanitize-FileName "${rawProdId}_${handle}"
    $prodImageFolderRel = "imagenes_bloomshell/$folderSlug"
    $prodImageFolderAbs = Join-Path $imagesBloomDir $folderSlug

    $prodAllImages = New-Object System.Collections.Generic.List[string]
    $prodAllLocalImages = New-Object System.Collections.Generic.List[string]

    if ($row.image -and $row.image.url) {
        $cleanU = ([string]$row.image.url -split "\?")[0]
        [void]$prodAllImages.Add($cleanU)
    }
    if ($shopifyProd -and $shopifyProd.images) {
        foreach ($im in $shopifyProd.images) {
            if ($im.src) {
                $cleanU = ([string]$im.src -split "\?")[0]
                if (-not $prodAllImages.Contains($cleanU)) {
                    [void]$prodAllImages.Add($cleanU)
                }
            }
        }
    }

    $imgIdx = 0
    foreach ($imgUrl in $prodAllImages) {
        $imgIdx++
        $uriObj = [System.Uri]$imgUrl
        $origFileName = [System.IO.Path]::GetFileName($uriObj.LocalPath)
        $safeOrigName = Sanitize-FileName $origFileName
        if (-not $safeOrigName.Contains(".")) { $safeOrigName += ".png" }
        $localFileName = "${imgIdx}_${safeOrigName}"
        $localFileAbs = Join-Path $prodImageFolderAbs $localFileName
        $localFileRel = "$prodImageFolderRel/$localFileName"
        if (-not $prodAllLocalImages.Contains($localFileRel)) {
            [void]$prodAllLocalImages.Add($localFileRel)
        }
        Register-ImageDownload $imgUrl $localFileAbs
    }

    $cleanSkusList = New-Object System.Collections.Generic.List[object]
    $prodTotalStock = 0
    $retailMin = $null
    $retailMax = $null
    $tier1Min = $null
    $tier2Min = $null
    $minQtyProd = 1
    $maxQtyProd = 0
    $mainSkuRef = [string]$row.defaultVariantSku

    foreach ($v in $row.variants) {
        $vId = [string]$v.numericVariantId
        $vSku = [string]$v.sku
        if (-not $mainSkuRef -and $vSku) { $mainSkuRef = $vSku }
        $vTitle = if ($v.title -and $v.title -ne "Default Title") { [string]$v.title } else { $title }
        $vPrice = 0.0; [void][double]::TryParse([string]$v.price, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$vPrice)
        $vStock = if ($null -ne $v.inventoryQuantity) { [int]$v.inventoryQuantity } else { 0 }
        if ($vStock -lt 0) { $vStock = 0 }
        $vAvail = [bool]$v.availableForSale -and ($vStock -gt 0)
        $prodTotalStock += $vStock

        $t1 = if ($v.tierPrices -and $v.tierPrices.rango1) { [double]$v.tierPrices.rango1 } else { $vPrice }
        $t2 = if ($v.tierPrices -and $v.tierPrices.rango2) { [double]$v.tierPrices.rango2 } else { $t1 }

        if ($vPrice -gt 0) {
            if ($null -eq $retailMin -or $vPrice -lt $retailMin) { $retailMin = $vPrice }
            if ($null -eq $retailMax -or $vPrice -gt $retailMax) { $retailMax = $vPrice }
        }
        if ($t1 -gt 0 -and ($null -eq $tier1Min -or $t1 -lt $tier1Min)) { $tier1Min = $t1 }
        if ($t2 -gt 0 -and ($null -eq $tier2Min -or $t2 -lt $tier2Min)) { $tier2Min = $t2 }

        if ($v.rules) {
            if ($v.rules.cantidadMinima -and [int]$v.rules.cantidadMinima -gt $minQtyProd) {
                $minQtyProd = [int]$v.rules.cantidadMinima
            }
            if ($v.rules.cantidadMaxima) {
                $maxQtyProd = [int]$v.rules.cantidadMaxima
            }
        }

        [void]$cleanSkusList.Add([ordered]@{
            skuId              = $vId
            reference          = $vSku
            name               = $vTitle
            nameComplete       = "$title ($vTitle)"
            ean                = ""
            color              = if ($v.title -ne "Default Title") { [string]$v.title } else { "" }
            tono               = ""
            variations         = ""
            price              = $vPrice
            listPrice          = $vPrice
            wholesaleTier1     = $t1
            wholesaleListPrice = $t1
            wholesaleTier2     = $t2
            discountPercent    = 0
            isAvailable        = $vAvail
            stock              = $vStock
            mainImageUrl       = if ($prodAllImages.Count -gt 0) { $prodAllImages[0] } else { "" }
            galleryImageUrls   = $prodAllImages
            pickerImageUrl     = ""
            localImages        = $prodAllLocalImages
        })
    }

    if ($null -eq $retailMin) { $retailMin = 0 }
    if ($null -eq $retailMax) { $retailMax = 0 }
    if ($null -eq $tier1Min) { $tier1Min = $retailMin }
    if ($null -eq $tier2Min) { $tier2Min = $tier1Min }

    $wholesaleSource = "API Mayorista Oficial Bloomshell"
    $minQtyText = "Min. $minQtyProd uds"
    if ($maxQtyProd -gt 0) { $minQtyText += " (Max. $maxQtyProd)" }
    if ($descText -match "DISPLAY\s*X\s*(\d+)") {
        $minQtyText += " | Display x$($Matches[1])"
    }

    $bsRankVal = if ($bloomBestSellingRankMap.ContainsKey($handle)) { [int]$bloomBestSellingRankMap[$handle] } else { 999 }
    $unifiedCat = Get-UnifiedCategory $title $catMain ($uniqueCols -join " ") $descText

    [void]$unifiedMarketList.Add([ordered]@{
        unifiedId            = "BLOOM_$rawProdId"
        supplier             = "Bloomshell"
        productId            = $rawProdId
        reference            = $mainSkuRef
        name                 = $title
        brand                = "Bloomshell"
        slug                 = $handle
        url                  = $prodUrl
        releaseDate          = if ($publishedAt) { ($publishedAt -split "T")[0] } else { "" }
        unifiedCategory      = $unifiedCat
        categoryMain         = $catMain
        subcategory          = ($uniqueCols -join ", ")
        clusters             = $uniqueCols
        retailPrice          = [double]$retailMin
        retailMaxPrice       = [double]$retailMax
        retailListPrice      = [double]$retailMin
        wholesaleTier1       = [double]$tier1Min
        wholesaleListPrice   = [double]$tier1Min
        wholesaleTier1Label  = "Mayorista Rango 1 (`$700k)"
        wholesaleTier2       = [double]$tier2Min
        wholesaleTier2Label  = "Mayorista Rango 2 (`$1.5M)"
        wholesaleSource      = $wholesaleSource
        minWholesaleQty      = [int]$minQtyProd
        minWholesaleQtyText  = $minQtyText
        totalStock           = [int]$prodTotalStock
        isAvailable          = ($prodTotalStock -gt 0)
        topSaleRank          = $bsRankVal
        scoreRank            = $bsRankVal
        variantsCount        = $cleanSkusList.Count
        variants             = $cleanSkusList
        allRemoteImages      = $prodAllImages
        allLocalImages       = $prodAllLocalImages
        imageFolderLocal     = $prodImageFolderRel
        descriptionText      = $descText
        specifications       = [ordered]@{
            unidadMinimaMayoristas = $minQtyText
            contenido              = ""
            pumUnidad              = ""
            pumMedida              = ""
            registroInvima         = "Notificacion Sanitaria Vigente"
            tipoDePiel             = "Todo tipo de piel"
            acabado                = ""
            formulaCosmetica       = ""
            beneficios             = $descText
            ingredientes           = ""
            cuidados               = ""
            garantia               = "Garantia Mayorista Bloomshell"
            informacionAdicional   = $erpBaseCostInfo
        }
    })
}

# ==============================================================================
# 5. CALCULAR METRICAS DE ESTUDIO DE MERCADO, ROTACION HISTORICA Y SCORING LOCAL
# ==============================================================================
$changeLogList = New-Object System.Collections.Generic.List[object]
$currentSnapshotItems = New-Object System.Collections.Generic.List[object]

foreach ($item in $unifiedMarketList) {
    $uId = [string]$item.unifiedId
    $retail = [double]$item.retailPrice
    $t1 = [double]$item.wholesaleTier1
    $t2 = [double]$item.wholesaleTier2
    $minQ = [int]$item.minWholesaleQty
    if ($minQ -le 0) { $minQ = 1 }

    $unitProfitT1 = if ($retail -gt $t1 -and $t1 -gt 0) { [math]::Round($retail - $t1, 0) } else { 0.0 }
    $unitProfitT2 = if ($retail -gt $t2 -and $t2 -gt 0) { [math]::Round($retail - $t2, 0) } else { 0.0 }
    $roiPctT1 = if ($t1 -gt 0 -and $retail -gt $t1) { [math]::Round((($retail - $t1) / $t1) * 100, 1) } else { 0.0 }
    $roiPctT2 = if ($t2 -gt 0 -and $retail -gt $t2) { [math]::Round((($retail - $t2) / $t2) * 100, 1) } else { 0.0 }
    $marginPctT1 = if ($retail -gt 0 -and $retail -gt $t1) { [math]::Round((($retail - $t1) / $retail) * 100, 1) } else { 0.0 }
    $minInvestmentT1 = [math]::Round($t1 * $minQ, 0)
    $minProfitPackT1 = [math]::Round($unitProfitT1 * $minQ, 0)

    $isNewInScan = $false
    $deltaStock = 0
    $deltaRetailPrice = 0.0
    $statusChange = "Estable"

    if ($prevSnapshotMap.ContainsKey($uId)) {
        $prev = $prevSnapshotMap[$uId]
        $prevStock = [int]$prev.totalStock
        $prevPrice = [double]$prev.retailPrice
        $deltaStock = $item.totalStock - $prevStock
        $deltaRetailPrice = $retail - $prevPrice

        if ($prevStock -eq 0 -and $item.totalStock -gt 0) {
            $statusChange = "Reabastecido (Volvio a Stock)"
        } elseif ($prevStock -gt 0 -and $item.totalStock -eq 0) {
            $statusChange = "Agotado Recientemente"
        } elseif ($deltaStock -le -10) {
            $statusChange = "Alta Rotacion (Bodega vendio $([math]::Abs($deltaStock)) uds)"
        } elseif ($deltaStock -ge 20) {
            $statusChange = "Ingreso de Inventario (+$deltaStock uds)"
        }

        if ($statusChange -ne "Estable" -or [math]::Abs($deltaRetailPrice) -ge 500) {
            [void]$changeLogList.Add([ordered]@{
                Fecha_Escaneo     = $scanTimestamp
                Proveedor         = $item.supplier
                ID_Unificado      = $uId
                Referencia        = $item.reference
                Producto          = $item.name
                Categoria         = $item.unifiedCategory
                Tipo_Cambio       = $statusChange
                Stock_Anterior    = $prevStock
                Stock_Actual      = $item.totalStock
                Diferencia_Stock  = $deltaStock
                Precio_Anterior   = $prevPrice
                Precio_Actual     = $retail
                Diferencia_Precio = $deltaRetailPrice
            })
        }
    } else {
        if ($item.supplier -eq "Trendy" -and $prevSnapshotMap.Count -gt 0) {
            $isNewInScan = $true
            $statusChange = "Nuevo en Catalogo (Lanzamiento Reciente)"
            [void]$changeLogList.Add([ordered]@{
                Fecha_Escaneo     = $scanTimestamp
                Proveedor         = $item.supplier
                ID_Unificado      = $uId
                Referencia        = $item.reference
                Producto          = $item.name
                Categoria         = $item.unifiedCategory
                Tipo_Cambio       = $statusChange
                Stock_Anterior    = 0
                Stock_Actual      = $item.totalStock
                Diferencia_Stock  = $item.totalStock
                Precio_Anterior   = 0
                Precio_Actual     = $retail
                Diferencia_Precio = 0
            })
        }
    }

    # 1. Trend Score (0 - 100)
    $rank = [int]$item.topSaleRank
    $trendScore = if ($rank -le 15) { 98 }
                  elseif ($rank -le 35) { 92 }
                  elseif ($rank -le 70) { 84 }
                  elseif ($rank -le 120) { 75 }
                  elseif ($rank -le 200) { 65 }
                  else { 50 }

    $clustersUpper = (Remove-Diacritics ($item.clusters -join " ")).ToUpper()
    $isNewCollection = ($clustersUpper -match "NUEVO|NUEVA|COLECCI|TRENDYLOCURA|IMPULSO") -or $isNewInScan
    if ($clustersUpper -match "IMPULSO|TRENDYLOCURA") { $trendScore = [math]::Min(100, $trendScore + 8) }
    if ($deltaStock -le -15) { $trendScore = [math]::Min(100, $trendScore + 10) }
    elseif ($deltaStock -le -5) { $trendScore = [math]::Min(100, $trendScore + 5) }

    # 2. Margin Score (0 - 100) basado en tu escala ($400k Trendy / $700k Bloomshell)
    $marginScore = if ($roiPctT1 -ge 110) { 98 }
                   elseif ($roiPctT1 -ge 85) { 92 }
                   elseif ($roiPctT1 -ge 60) { 84 }
                   elseif ($roiPctT1 -ge 42) { 75 }
                   elseif ($roiPctT1 -ge 25) { 60 }
                   else { 35 }

    if ($minInvestmentT1 -gt 180000) { $marginScore = [math]::Max(20, $marginScore - 30) }
    elseif ($minInvestmentT1 -gt 90000) { $marginScore = [math]::Max(35, $marginScore - 15) }
    elseif ($minInvestmentT1 -le 35000 -and $roiPctT1 -ge 45) { $marginScore = [math]::Min(100, $marginScore + 6) }

    # 3. Local Fit Score (0 - 100) - Calibrado para Roldanillo, Cartago y Valle del Cauca (Clima Calido)
    $localFitScore = 60
    $localReasons = New-Object System.Collections.Generic.List[string]
    $fullSearch = (Remove-Diacritics "$($item.name) $($item.unifiedCategory) $($item.descriptionText) $($item.specifications.acabado) $($item.specifications.beneficios)").ToUpper()

    if ($fullSearch -match "FIJADOR|FIX|MATIFICANTE|MATE|CONTROL GRASA|OIL CONTROL|POLVO SUELTO|TRASLUCIDO|BANANA|WATERPROOF|APRUEBA DE AGUA|RESISTENTE AL AGUA|LARGA DURACI") {
        $localFitScore += 18
        [void]$localReasons.Add("Ideal clima calido (Roldanillo/Cartago): resistencia al calor/sudor y control brillo")
    }
    if ($fullSearch -match "CEJA|LAMINATION|TINTA|LIP OIL|BRILLO HIDRATANTE|RUBOR LIQUIDO|RUBOR EN CREMA|CORRECTOR|BORLA|BEAUTY BLENDER|PESTANINA") {
        $localFitScore += 14
        [void]$localReasons.Add("Categoria de altisima rotacion diaria en el Valle del Cauca")
    }
    if ($fullSearch -match "DESTELLO|ILUMINADOR CORPORAL|SPLASH|TONICO DE ROSAS|HIDROGEL|PROTECTOR SOLAR|NIACINAMIDA|MULTIGEL") {
        $localFitScore += 12
        [void]$localReasons.Add("Alta demanda en clima calido: piel fresca, hidratacion ligera y brillo corporal")
    }

    if ($retail -ge 5000 -and $retail -le 22000) {
        $localFitScore += 14
        [void]$localReasons.Add("Precio detal ganador ($($retail.ToString('N0')) COP): compra por impulso en Roldanillo y Cartago")
    } elseif ($retail -gt 22000 -and $retail -le 32000) {
        $localFitScore += 7
        [void]$localReasons.Add("Ticket medio competitivo ($($retail.ToString('N0')) COP)")
    } elseif ($retail -gt 42000) {
        $localFitScore -= 12
    }

    $localFitScore = [math]::Min(100, [math]::Max(25, $localFitScore))
    if ($localReasons.Count -eq 0) {
        [void]$localReasons.Add("Complemento de catalogo general")
    }

    # 4. Freshness & Stock Health Score (0 - 100)
    $freshnessScore = 65
    if ($isNewCollection) { $freshnessScore += 20 }
    if ($item.totalStock -ge ($minQ * 5)) { $freshnessScore += 15 }
    elseif ($item.totalStock -le 0) { $freshnessScore = 0 }
    $freshnessScore = [math]::Min(100, $freshnessScore)

    $opportunityScore = [math]::Round(
        ($trendScore * 0.34) +
        ($marginScore * 0.28) +
        ($localFitScore * 0.26) +
        ($freshnessScore * 0.12), 1
    )
    if (-not $item.isAvailable -or $item.totalStock -lt $minQ) {
        $opportunityScore = [math]::Round($opportunityScore * 0.35, 1)
    }

    $recTier = "COMPLEMENTO DE SURTIDO"
    $recCode = "COMPLEMENTO"
    if (-not $item.isAvailable -or $item.totalStock -lt $minQ) {
        $recTier = "AGOTADO EN PROVEEDOR"
        $recCode = "AGOTADO"
    } elseif ($minInvestmentT1 -gt 160000) {
        $recTier = "DISPLAY COSTOSO (Alto Capital Minimo)"
        $recCode = "RIESGO_CAPITAL"
    } elseif ($opportunityScore -ge 84 -and $rank -le 65) {
        $recTier = "COMPRA OBLIGATORIA (Top Ventas + Clima Calido)"
        $recCode = "COMPRA_OBLIGATORIA"
    } elseif ($roiPctT1 -ge 75 -and $retail -le 24000 -and $minInvestmentT1 -le 60000) {
        $recTier = "VACA LECHERA (Alto Margen + Rapida Salida)"
        $recCode = "VACA_LECHERA"
    } elseif ($isNewCollection -and $opportunityScore -ge 74) {
        $recTier = "LANZAMIENTO EN TENDENCIA"
        $recCode = "LANZAMIENTO_TENDENCIA"
    }

    $item["unitProfitTier1"]     = $unitProfitT1
    $item["unitProfitTier2"]     = $unitProfitT2
    $item["roiPercentTier1"]     = $roiPctT1
    $item["roiPercentTier2"]     = $roiPctT2
    $item["marginPercentTier1"]  = $marginPctT1
    $item["minInvestmentTier1"]  = $minInvestmentT1
    $item["minProfitPackTier1"]  = $minProfitPackT1
    $item["isNewInScan"]         = $isNewInScan
    $item["isNewCollection"]     = [bool]$isNewCollection
    $item["deltaStock"]          = $deltaStock
    $item["deltaRetailPrice"]    = $deltaRetailPrice
    $item["statusChange"]        = $statusChange
    $item["trendScore"]          = $trendScore
    $item["marginScore"]         = $marginScore
    $item["localFitScore"]       = $localFitScore
    $item["localFitReasons"]     = $localReasons
    $item["opportunityScore"]    = $opportunityScore
    $item["recommendationTier"]  = $recTier
    $item["recommendationCode"]  = $recCode

    [void]$currentSnapshotItems.Add([ordered]@{
        unifiedId      = $uId
        supplier       = $item.supplier
        productId      = $item.productId
        reference      = $item.reference
        name           = $item.name
        retailPrice    = $retail
        wholesaleTier1 = $t1
        wholesaleTier2 = $t2
        totalStock     = $item.totalStock
        isAvailable    = $item.isAvailable
        topSaleRank    = $rank
    })
}

# ==============================================================================
# 6. GUARDAR SNAPSHOT HISTORICO, ARCHIVOS JS Y REPORTES CSV/EXCEL
# ==============================================================================
Write-Host "================================================================="
Write-Host "FASE 5: Guardando Historial de Escaneo, Reportes Excel y Datos Web..."
Write-Host "================================================================="

$newSnapObj = [ordered]@{
    scanId    = $scanId
    timestamp = $scanTimestamp
    note      = "Escaneo automatico Trendy + Bloomshell"
    items     = $currentSnapshotItems
}
$newSnapPath = Join-Path $histDir "snapshot_${scanId}.json"
[System.IO.File]::WriteAllText($newSnapPath, ($newSnapObj | ConvertTo-Json -Depth 8), $utf8NoBom)
Write-Host "   -> Snapshot historico guardado: $newSnapPath"

$allSnapFiles = @(Get-ChildItem -Path $histDir -Filter "snapshot_*.json" | Sort-Object Name)
$scanHistoryMeta = New-Object System.Collections.Generic.List[object]
foreach ($sf in $allSnapFiles) {
    try {
        $so = [System.IO.File]::ReadAllText($sf.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        [void]$scanHistoryMeta.Add([ordered]@{
            fileName   = $sf.Name
            scanId     = $so.scanId
            timestamp  = $so.timestamp
            note       = $so.note
            itemsCount = $so.items.Count
        })
    } catch {}
}
$histIndexPath = Join-Path $histDir "indice_escaneos.json"
[System.IO.File]::WriteAllText($histIndexPath, ($scanHistoryMeta | ConvertTo-Json -Depth 6), $utf8NoBom)

$cleanJsonPath = Join-Path $dataDir "productos_estructurados.json"
$cleanJsonContent = $cleanProductsJsonList | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($cleanJsonPath, $cleanJsonContent, $utf8NoBom)

$jsDataPath = Join-Path $dataDir "catalogo_data.js"
[System.IO.File]::WriteAllText($jsDataPath, ("window.TRENDY_CATALOG_DATA = " + $cleanJsonContent + ";"), $utf8NoBom)

function Save-CsvUtf8Bom($list, [string]$filePath, [char]$delimiter) {
    if (-not $list -or $list.Count -eq 0) { return }
    $csvLines = $list | ConvertTo-Csv -NoTypeInformation -Delimiter $delimiter
    $content = $csvLines -join "`r`n"
    [System.IO.File]::WriteAllText($filePath, $content, $utf8Bom)
    Write-Host "   -> CSV Guardado: $filePath ($($list.Count) filas)"
}

Save-CsvUtf8Bom $skuRows (Join-Path $dataDir "variantes_skus.csv") ','
Save-CsvUtf8Bom $skuRows (Join-Path $dataDir "variantes_skus_excel_es.csv") ';'
Save-CsvUtf8Bom $productRows (Join-Path $dataDir "resumen_productos.csv") ','
Save-CsvUtf8Bom $productRows (Join-Path $dataDir "resumen_productos_excel_es.csv") ';'

$marketCsvRows = New-Object System.Collections.Generic.List[object]
$sortedMarket = $unifiedMarketList | Sort-Object { [double]$_.opportunityScore } -Descending

foreach ($m in $sortedMarket) {
    [void]$marketCsvRows.Add((New-Object PSObject -Property ([ordered]@{
        Puntaje_Oportunidad        = $m.opportunityScore
        Recomendacion              = $m.recommendationTier
        Proveedor                  = $m.supplier
        Ranking_Ventas_Proveedor   = if ($m.topSaleRank -lt 999) { "#$($m.topSaleRank)" } else { "N/A" }
        ID_Unificado               = $m.unifiedId
        Referencia_SKU             = $m.reference
        Producto                   = $m.name
        Categoria_Unificada        = $m.unifiedCategory
        Precio_Detal_COP           = $m.retailPrice
        Costo_Mayorista_Tu_Escala  = $m.wholesaleTier1
        Escala_Mayorista_Base      = $m.wholesaleTier1Label
        Costo_Mayorista_Escala_2   = $m.wholesaleTier2
        Ganancia_Unidad_COP        = $m.unitProfitTier1
        ROI_Porcentaje             = "$($m.roiPercentTier1)%"
        Margen_Sobre_Venta         = "$($m.marginPercentTier1)%"
        Minimo_Mayorista_Uds       = $m.minWholesaleQty
        Inversion_Minima_Ref_COP   = $m.minInvestmentTier1
        Ganancia_Minima_Ref_COP    = $m.minProfitPackTier1
        Stock_Bodega_Proveedor     = $m.totalStock
        Variacion_Stock_Escaneo    = $m.deltaStock
        Estado_Escaneo             = $m.statusChange
        Afinidad_Valle_Calido      = $m.localFitScore
        Razones_Mercado_Local      = ($m.localFitReasons -join " | ")
        Variantes_Count            = $m.variantsCount
        Fecha_Lanzamiento          = $m.releaseDate
        URL_Proveedor              = $m.url
        Carpeta_Imagenes_Local     = $m.imageFolderLocal
    })))
}

Save-CsvUtf8Bom $marketCsvRows (Join-Path $dataDir "estudio_mercado_recomendaciones_excel.csv") ';'
Save-CsvUtf8Bom $changeLogList (Join-Path $dataDir "bitacora_cambios_escaneo_excel.csv") ';'

$masterPayload = [ordered]@{
    scanId            = $scanId
    scanTimestamp     = $scanTimestamp
    previousScanDate  = $prevScanDate
    targetRegion      = "Roldanillo, Cartago y Valle del Cauca (Clima Calido)"
    wholesaleBudgets  = [ordered]@{
        trendyTargetCOP     = 400000
        trendyTier2COP      = 1000000
        bloomshellTargetCOP = 700000
        bloomshellTier2COP  = 1500000
    }
    scanHistory       = $scanHistoryMeta
    recentChanges     = $changeLogList
    products          = $sortedMarket
}

$marketJsonPath = Join-Path $dataDir "mercado_unificado.json"
$marketJsonStr = $masterPayload | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($marketJsonPath, $marketJsonStr, $utf8NoBom)

$marketJsPath = Join-Path $dataDir "mercado_unificado_data.js"
[System.IO.File]::WriteAllText($marketJsPath, ("window.MARKET_STUDY_DATA = " + $marketJsonStr + ";"), $utf8NoBom)
Write-Host "   -> Guardado motor de datos web: $marketJsPath"

# ==============================================================================
# 7. DESCARGAR TODAS LAS IMAGENES (TRENDY + BLOOMSHELL)
# ==============================================================================
if (-not $OmitirImagenes) {
    $jobsList = New-Object System.Collections.Generic.List[ImageDownloadJob]
    foreach ($job in $imageJobsByUrl.Values) {
        [void]$jobsList.Add($job)
    }
    [MarketScannerHttp]::DownloadImagesParallel($jobsList, $MaxHilosImagenes)
}

$trendyCount = ($unifiedMarketList | Where-Object { $_.supplier -eq "Trendy" }).Count
$bloomCount = ($unifiedMarketList | Where-Object { $_.supplier -eq "Bloomshell" }).Count
$topPicksCount = ($unifiedMarketList | Where-Object { $_.recommendationCode -in @("COMPRA_OBLIGATORIA", "VACA_LECHERA", "LANZAMIENTO_TENDENCIA") }).Count

Write-Host "================================================================="
Write-Host "ESCANEO DE MERCADO Y PROVEEDORES COMPLETADO CON EXITO"
Write-Host "Fecha de escaneo     : $scanTimestamp"
Write-Host "Productos Trendy     : $trendyCount"
Write-Host "Productos Bloomshell : $bloomCount"
Write-Host "Total Unificado      : $($unifiedMarketList.Count)"
Write-Host "Oportunidades Top    : $topPicksCount productos recomendados para Roldanillo/Cartago/Valle"
Write-Host "Cambios detectados   : $($changeLogList.Count) movimientos de stock/novedades"
Write-Host "================================================================="
