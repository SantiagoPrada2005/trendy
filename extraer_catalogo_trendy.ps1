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

public static class FastDownloader
{
    private static readonly HttpClient client;

    static FastDownloader()
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
        client.DefaultRequestHeaders.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
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

    public static void DownloadImagesParallel(List<ImageDownloadJob> jobs, int maxConcurrency = 24)
    {
        int total = jobs.Count;
        int completed = 0;
        int downloaded = 0;
        int skipped = 0;
        int failed = 0;

        Console.WriteLine(string.Format("[IMAGENES] Iniciando descarga paralela de {0} imagenes unicas ({1} hilos)...", total, maxConcurrency));

        var options = new ParallelOptions { MaxDegreeOfParallelism = maxConcurrency };
        Parallel.ForEach(jobs, options, job =>
        {
            try
            {
                bool allExist = true;
                foreach (var p in job.TargetPaths)
                {
                    if (!File.Exists(p) || new FileInfo(p).Length == 0)
                    {
                        allExist = false;
                        break;
                    }
                }

                if (allExist)
                {
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
            if (curr % 200 == 0 || curr == total)
            {
                Console.WriteLine(string.Format("[IMAGENES] Progreso: {0}/{1} (Descargadas: {2}, Ya existian: {3}, Fallidas: {4})",
                    curr, total, downloaded, skipped, failed));
            }
        });
    }
}
"@

Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies "System.Net.Http", "System.Core", "System.Xml"

$baseDir = $PSScriptRoot
if (-not $baseDir) { $baseDir = "c:\Users\Usuario\Documents\trendy" }
$dataDir = Join-Path $baseDir "datos"
$imagesDir = Join-Path $baseDir "imagenes"

New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
New-Item -ItemType Directory -Force -Path $imagesDir | Out-Null

Write-Host "1. Descargando catalogo completo de productos desde API VTEX de Maquillaje Trendy Shop..."
$allProducts = @{}
$queries = @(
    "",
    "O=OrderByNameASC&",
    "O=OrderByReleaseDateDESC&",
    "O=OrderByScoreDESC&",
    "O=OrderByTopSaleDESC&"
)

# Agregar tambien consultas por cada categoria principal del arbol
try {
    $catTreeJson = [FastDownloader]::GetUtf8String("https://www.maquillajetrendyshop.com/api/catalog_system/pub/category/tree/5")
    [System.IO.File]::WriteAllText((Join-Path $dataDir "categorias_arbol.json"), $catTreeJson, (New-Object System.Text.UTF8Encoding($false)))
    $catTree = $catTreeJson | ConvertFrom-Json
    foreach ($rootCat in $catTree) {
        $queries += "fq=C:/$($rootCat.id)/&"
    }
} catch {
    Write-Warning "No se pudo obtener el arbol de categorias opcional: $_"
}

foreach ($q in $queries) {
    $from = 0
    $step = 50
    while ($true) {
        $to = $from + $step - 1
        $url = "https://www.maquillajetrendyshop.com/api/catalog_system/pub/products/search?${q}_from=$from&_to=$to"
        $json = [FastDownloader]::GetUtf8String($url)
        if ([string]::IsNullOrWhiteSpace($json)) { break }
        $items = $json | ConvertFrom-Json
        if (-not $items -or $items.Count -eq 0) { break }
        foreach ($p in $items) {
            $idStr = [string]$p.productId
            if (-not $allProducts.ContainsKey($idStr)) {
                $allProducts[$idStr] = $p
            }
        }
        if ($items.Count -lt $step) { break }
        $from += $step
        if ($from -ge 2500) { break }
    }
}
Write-Host "   -> Productos unicos recolectados por busquedas y categorias: $($allProducts.Count)"

# Verificar Sitemap por si hay algun producto extra activo
Write-Host "2. Verificando Sitemap de productos..."
try {
    $sitemapXml = [FastDownloader]::GetUtf8String("https://www.maquillajetrendyshop.com/sitemap/product-0.xml")
    $matches = [regex]::Matches($sitemapXml, "<loc>https://www\.maquillajetrendyshop\.com/([^<]+)/p</loc>")
    $existingSlugs = @{}
    foreach ($p in $allProducts.Values) {
        if ($p.linkText) { $existingSlugs[$p.linkText.ToLower()] = $true }
    }
    foreach ($m in $matches) {
        $slug = $m.Groups[1].Value.ToLower()
        if (-not $existingSlugs.ContainsKey($slug)) {
            $url = "https://www.maquillajetrendyshop.com/api/catalog_system/pub/products/search/$slug/p"
            $json = [FastDownloader]::GetUtf8String($url)
            if (-not [string]::IsNullOrWhiteSpace($json) -and $json -ne "[]") {
                $items = $json | ConvertFrom-Json
                foreach ($p in $items) {
                    $idStr = [string]$p.productId
                    if (-not $allProducts.ContainsKey($idStr)) {
                        $allProducts[$idStr] = $p
                    }
                }
            }
        }
    }
} catch {
    Write-Warning "No se pudo consultar el sitemap opcional: $_"
}

$sortedProducts = $allProducts.Values | Sort-Object { [int]$_.productId }
Write-Host "Total de productos unicos activos encontrados: $($sortedProducts.Count)"

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
    $clean = $name
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

$skuRows = New-Object System.Collections.Generic.List[object]
$productRows = New-Object System.Collections.Generic.List[object]
$cleanProductsJsonList = New-Object System.Collections.Generic.List[object]
$imageJobsByUrl = @{}

foreach ($p in $sortedProducts) {
    $prodId = [string]$p.productId
    $prodName = [string]$p.productName
    $prodRef = [string]$p.productReference
    $brand = [string]$p.brand
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
    $clustersStr = ($clustersList | Select-Object -Unique) -join " | "

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
    $prodImageFolderAbs = Join-Path $imagesDir $folderSlug

    $prodMinPrice = $null
    $prodMaxPrice = $null
    $prodTotalStock = 0
    $prodAllImages = New-Object System.Collections.Generic.List[string]
    $prodAllVariantNames = New-Object System.Collections.Generic.List[string]
    $cleanSkusList = New-Object System.Collections.Generic.List[object]

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

        $discountPct = 0.0
        if ($listPrice -gt 0 -and $price -lt $listPrice) {
            $discountPct = [math]::Round((($listPrice - $price) / $listPrice) * 100, 2)
        }

        if ($price -gt 0) {
            if ($null -eq $prodMinPrice -or $price -lt $prodMinPrice) { $prodMinPrice = $price }
            if ($null -eq $prodMaxPrice -or $price -gt $prodMaxPrice) { $prodMaxPrice = $price }
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
        }

        $mainImgUrl = if ($skuGalleryUrls.Count -gt 0) { $skuGalleryUrls[0] } else { "" }

        $skuRow = [ordered]@{
            Producto_ID              = $prodId
            SKU_ID                   = $skuId
            Referencia_Producto      = $prodRef
            Referencia_SKU           = $refIdVal
            Nombre_SKU               = $skuName
            Nombre_Producto          = $prodName
            Nombre_Completo          = $skuNameComplete
            Marca                    = $brand
            Categoria_Principal      = $catNivel1
            Subcategoria_Nivel_2     = $catNivel2
            Subcategoria_Nivel_3     = $catNivel3
            Ruta_Categorias          = $mainCategoryRoute
            Color                    = $colorVal
            Tono                     = $tonoVal
            Variaciones              = $variationsSummary
            Precio_Venta_COP         = $price
            Precio_Lista_COP         = $listPrice
            Precio_Sin_Descuento_COP = $priceWithoutDiscount
            Descuento_Porcentaje     = $discountPct
            Disponible               = if ($isAvailable) { "SI" } else { "NO" }
            Stock_Disponible         = $stock
            Unidad_Minima_Mayoristas = $unidadMinMayorista
            Contenido                = $contenido
            PUM_Unidad               = $pumUnidad
            PUM_Medida               = $pumMedida
            Registro_Invima          = $registroInvima
            Tipo_De_Piel             = $tipoPiel
            Acabado                  = $acabado
            Formula_Cosmetica        = $formulaCosmetica
            Beneficios               = $beneficios
            Ingredientes             = $ingredientes
            Cuidados                 = $cuidados
            Garantia                 = $garantia
            Informacion_Adicional    = $infoAdicional
            Etiquetas_Clusters       = $clustersStr
            EAN                      = $ean
            Unidad_Medida_Venta      = $measureUnit
            Multiplicador_Unidad     = $unitMult
            Fecha_Lanzamiento        = $releaseDate
            Resumen_Corto            = $complementName
            Meta_Descripcion         = $metaDesc
            Descripcion_Texto        = $descText
            URL_Producto             = $prodUrl
            Imagen_Principal_URL     = $mainImgUrl
            Imagenes_Galeria_URLs    = ($skuGalleryUrls -join " | ")
            Imagen_Selector_Color_URL= $pickerUrl
            Carpeta_Imagenes_Local   = $prodImageFolderRel
            Archivos_Imagenes_Local  = ($skuLocalFiles -join " | ")
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
    $prodMainImg = if ($prodAllImages.Count -gt 0) { $prodAllImages[0] } else { "" }

    $prodRow = [ordered]@{
        Producto_ID              = $prodId
        Referencia_Producto      = $prodRef
        Nombre_Producto          = $prodName
        Marca                    = $brand
        Categoria_Principal      = $catNivel1
        Subcategoria_Nivel_2     = $catNivel2
        Subcategoria_Nivel_3     = $catNivel3
        Ruta_Categorias          = $mainCategoryRoute
        Cantidad_Variantes_SKUs  = $itemsList.Count
        Variantes_Tonos          = (($prodAllVariantNames | Select-Object -Unique) -join " | ")
        Precio_Minimo_COP        = $prodMinPrice
        Precio_Maximo_COP        = $prodMaxPrice
        Tiene_Stock_Disponible   = if ($prodTotalStock -gt 0) { "SI" } else { "NO" }
        Stock_Total_Acumulado    = $prodTotalStock
        Unidad_Minima_Mayoristas = $unidadMinMayorista
        Contenido                = $contenido
        PUM_Unidad               = $pumUnidad
        PUM_Medida               = $pumMedida
        Registro_Invima          = $registroInvima
        Tipo_De_Piel             = $tipoPiel
        Acabado                  = $acabado
        Formula_Cosmetica        = $formulaCosmetica
        Beneficios               = $beneficios
        Ingredientes             = $ingredientes
        Cuidados                 = $cuidados
        Garantia                 = $garantia
        Informacion_Adicional    = $infoAdicional
        Etiquetas_Clusters       = $clustersStr
        Fecha_Lanzamiento        = $releaseDate
        Meta_Descripcion         = $metaDesc
        Descripcion_Texto        = $descText
        URL_Producto             = $prodUrl
        Imagen_Principal_URL     = $prodMainImg
        Todas_Las_Imagenes_URLs  = ($prodAllImages -join " | ")
        Carpeta_Imagenes_Local   = $prodImageFolderRel
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
        clusters             = ($clustersList | Select-Object -Unique)
        minPrice             = $prodMinPrice
        maxPrice             = $prodMaxPrice
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
}

Write-Host "3. Guardando archivos JSON y CSV compatibles con Excel (UTF-8 con BOM)..."
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$cleanJsonPath = Join-Path $dataDir "productos_estructurados.json"
$cleanJsonContent = $cleanProductsJsonList | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($cleanJsonPath, $cleanJsonContent, $utf8NoBom)
Write-Host "   -> Guardado: $cleanJsonPath"

$jsDataPath = Join-Path $dataDir "catalogo_data.js"
[System.IO.File]::WriteAllText($jsDataPath, ("window.TRENDY_CATALOG_DATA = " + $cleanJsonContent + ";"), $utf8NoBom)
Write-Host "   -> Guardado: $jsDataPath"

$rawJsonPath = Join-Path $dataDir "productos_vtex_raw.json"
$rawJsonContent = $sortedProducts | ConvertTo-Json -Depth 15
[System.IO.File]::WriteAllText($rawJsonPath, $rawJsonContent, $utf8NoBom)
Write-Host "   -> Guardado: $rawJsonPath"

function Save-CsvUtf8Bom($list, [string]$filePath, [char]$delimiter) {
    $csvLines = $list | ConvertTo-Csv -NoTypeInformation -Delimiter $delimiter
    $content = $csvLines -join "`r`n"
    [System.IO.File]::WriteAllText($filePath, $content, $utf8Bom)
    Write-Host "   -> Guardado: $filePath ($($list.Count) filas)"
}

Save-CsvUtf8Bom $skuRows (Join-Path $dataDir "variantes_skus.csv") ','
Save-CsvUtf8Bom $skuRows (Join-Path $dataDir "variantes_skus_excel_es.csv") ';'

Save-CsvUtf8Bom $productRows (Join-Path $dataDir "resumen_productos.csv") ','
Save-CsvUtf8Bom $productRows (Join-Path $dataDir "resumen_productos_excel_es.csv") ';'

$jobsList = New-Object System.Collections.Generic.List[ImageDownloadJob]
foreach ($job in $imageJobsByUrl.Values) {
    [void]$jobsList.Add($job)
}

[FastDownloader]::DownloadImagesParallel($jobsList, 24)

Write-Host "================================================================="
Write-Host "EXTRACCION COMPLETADA CON EXITO"
Write-Host "Productos unicos: $($productRows.Count)"
Write-Host "Variantes / SKUs: $($skuRows.Count)"
Write-Host "Imagenes unicas : $($jobsList.Count)"
Write-Host "Carpeta de datos: $dataDir"
Write-Host "Carpeta imagenes: $imagesDir"
Write-Host "================================================================="
