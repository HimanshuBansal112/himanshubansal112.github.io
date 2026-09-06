$ErrorActionPreference = 'Stop'

$repoRoot = (& git rev-parse --show-toplevel 2>$null).Trim()
if (-not $repoRoot) {
  Write-Error 'Commit blocked: this hook must run inside a Git repository.'
  exit 1
}

$textExtensions = @(
  '.asm', '.c', '.cc', '.cfg', '.conf', '.cpp', '.cs', '.css', '.csv', '.env',
  '.go', '.h', '.hh', '.hpp', '.html', '.ini', '.java', '.js', '.json', '.jsx',
  '.md', '.php', '.ps1', '.py', '.rb', '.rs', '.scss', '.sh', '.sql', '.svg',
  '.tex', '.toml', '.ts', '.tsx', '.txt', '.vue', '.xml', '.yaml', '.yml'
)

$textFileNames = @(
  'Dockerfile', 'Makefile', 'README', 'README.md', '.gitignore', '.gitattributes'
)

$phonePatterns = @(
  '(?<!\d)(?:\+?91[\s.-]?)?[6-9]\d{4}[\s.-]?\d{5}(?!\d)',
  '(?<!\d)(?:\+?1[\s.-]?)?(?:\([2-9]\d{2}\)|[2-9]\d{2})[\s.-]?\d{3}[\s.-]?\d{4}(?!\d)',
  '(?<!\d)\+?[1-9]\d{0,2}[\s.-]\d{3,4}[\s.-]\d{4}(?!\d)'
)

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('hb-phone-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

function Save-StagedBlob {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Destination
  )

  $processInfo = New-Object Diagnostics.ProcessStartInfo
  $processInfo.FileName = 'git'
  $processInfo.WorkingDirectory = $repoRoot
  $processInfo.UseShellExecute = $false
  $processInfo.CreateNoWindow = $true
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true
  $indexPath = ':' + $RelativePath
  $processInfo.Arguments = 'cat-file blob "' + $indexPath.Replace('"', '\"') + '"'

  $process = New-Object Diagnostics.Process
  $process.StartInfo = $processInfo
  [void]$process.Start()

  $output = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $process.StandardOutput.BaseStream.CopyTo($output)
  }
  finally {
    $output.Dispose()
  }

  $errorText = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    throw "Could not read staged file '$RelativePath': $errorText"
  }
}

function Expand-DeflateStream {
  param([byte[]]$Bytes)

  foreach ($offset in @(0, 2)) {
    if ($Bytes.Length -le $offset) { continue }

    $input = New-Object IO.MemoryStream
    $output = New-Object IO.MemoryStream
    try {
      $input.Write($Bytes, $offset, $Bytes.Length - $offset)
      $input.Position = 0
      $deflate = New-Object IO.Compression.DeflateStream($input, [IO.Compression.CompressionMode]::Decompress)
      $deflate.CopyTo($output)
      $deflate.Dispose()
      return [Text.Encoding]::GetEncoding(28591).GetString($output.ToArray())
    }
    catch {
    }
    finally {
      $input.Dispose()
      $output.Dispose()
    }
  }

  return ''
}

function Get-PdfCandidateText {
  param([Parameter(Mandatory = $true)][string]$PdfPath)

  $pdfBytes = [IO.File]::ReadAllBytes($PdfPath)
  $latin1 = [Text.Encoding]::GetEncoding(28591)
  $rawText = $latin1.GetString($pdfBytes)
  $builder = New-Object Text.StringBuilder
  [void]$builder.AppendLine($rawText)

  $cursor = 0
  while (($streamStart = $rawText.IndexOf('stream', $cursor, [StringComparison]::Ordinal)) -ge 0) {
    $dataStart = $streamStart + 6
    if ($dataStart -lt $pdfBytes.Length -and $pdfBytes[$dataStart] -eq 13) { $dataStart++ }
    if ($dataStart -lt $pdfBytes.Length -and $pdfBytes[$dataStart] -eq 10) { $dataStart++ }

    $streamEnd = $rawText.IndexOf('endstream', $dataStart, [StringComparison]::Ordinal)
    if ($streamEnd -lt 0 -or $streamEnd -le $dataStart) { break }

    $dictionaryStart = $rawText.LastIndexOf('<<', $streamStart, [StringComparison]::Ordinal)
    $dictionary = if ($dictionaryStart -ge 0) { $rawText.Substring($dictionaryStart, $streamStart - $dictionaryStart) } else { '' }

    if ($dictionary -match '/FlateDecode') {
      $length = $streamEnd - $dataStart
      if ($length -gt 0) {
        $streamBytes = New-Object byte[] $length
        [Array]::Copy($pdfBytes, $dataStart, $streamBytes, 0, $length)
        $expanded = Expand-DeflateStream $streamBytes
        if ($expanded) { [void]$builder.AppendLine($expanded) }
      }
    }

    $cursor = $streamEnd + 9
  }

  return $builder.ToString()
}

function Get-PdfText {
  param([Parameter(Mandatory = $true)][string]$PdfPath)

  $pdftotext = Get-Command pdftotext -ErrorAction SilentlyContinue
  if ($pdftotext) {
    return ((& $pdftotext.Source -layout $PdfPath - 2>$null) -join "`n")
  }

  return Get-PdfCandidateText $PdfPath
}

function Find-PhoneMatch {
  param([Parameter(Mandatory = $true)][string]$Text)

  foreach ($pattern in $phonePatterns) {
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { return $match }
  }

  return $null
}

try {
  $stagedPaths = @(& git diff --cached --name-only --diff-filter=ACMR --)
  $findings = New-Object Collections.Generic.List[string]

  foreach ($relativePath in $stagedPaths) {
    if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }

    $extension = [IO.Path]::GetExtension($relativePath).ToLowerInvariant()
    $leafName = [IO.Path]::GetFileName($relativePath)
    $isPdf = $extension -eq '.pdf'
    $isText = ($textExtensions -contains $extension) -or ($textFileNames -contains $leafName)
    if (-not $isPdf -and -not $isText) { continue }

    $tempPath = Join-Path $tempDir ([guid]::NewGuid().ToString('N') + $extension)
    Save-StagedBlob -RelativePath $relativePath -Destination $tempPath

    $content = if ($isPdf) {
      Get-PdfText -PdfPath $tempPath
    }
    else {
      [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($tempPath))
    }

    $match = Find-PhoneMatch -Text $content
    if ($match) {
      if ($isPdf) {
        [void]$findings.Add("$relativePath : phone-like number detected in PDF content")
      }
      else {
        $lineNumber = (($content.Substring(0, $match.Index) -split "`n").Count)
        [void]$findings.Add("$relativePath : phone-like number detected near line $lineNumber")
      }
    }
  }

  if ($findings.Count -gt 0) {
    Write-Host ''
    Write-Host 'Commit blocked: a phone-like number was found in staged content.' -ForegroundColor Red
    Write-Host 'Remove it from the file or PDF, stage the change again, and retry the commit.' -ForegroundColor Yellow
    foreach ($finding in $findings) { Write-Host (' - ' + $finding) }
    Write-Host ''
    exit 1
  }

  exit 0
}
catch {
  Write-Error ('Commit blocked: phone-number scan failed. ' + $_.Exception.Message)
  exit 1
}
finally {
  if (Test-Path -LiteralPath $tempDir) {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
