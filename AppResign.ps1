param (
    [Parameter(Mandatory = $true)][System.IO.FileInfo]$PackagePath,
    [Parameter(Mandatory = $false)][System.IO.FileInfo]$CertificatePath,
    [Parameter(Mandatory = $false)][string]$CertificatePassword
)

function GetWinSdkDir {
    $dir = Get-Item -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $dir = Get-ChildItem "$dir\10.*" | Sort-Object -Descending
    $dir = $dir[0]
    $dir = Get-Item -Path "$dir\x64"
    return $dir
}

function CreateEmptyDir {
    param ([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$path)

    if (Test-Path $path ) {
        Remove-Item -Path $path -Recurse -Force
    }
    return New-Item -Path $path -ItemType Directory
}

function RemoveMetadata {
    param ([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$path)

    Remove-Item -Path "$path\AppxMetadata" -Recurse -Force
    Remove-Item -Path "$path\AppxBlockMap.xml"
    Remove-Item -Path "$path\AppxSignature.p7x"
}

function GetSigningCertificate {
    $cert = $null
    if ($CertificatePath) {
        if ($CertificatePassword) {
            $certPw = ConvertTo-SecureString -String $CertificatePassword -Force -AsPlainText
            $cert = Get-PfxData -FilePath $CertificatePath.FullName -Password $certPw
        }
        else {
            $cert = Get-PfxData -FilePath $CertificatePath.FullName
        }
        $cert = $cert.EndEntityCertificates[0]
    }
    else {
        $codeSigningSubject = "CN=AppPinning Code Sign"
        $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $codeSigningSubject }
        if ($cert.count -eq 0) {
            $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $codeSigningSubject -KeyExportPolicy Exportable -CertStoreLocation Cert:\CurrentUser\My\ -NotAfter (Get-Date).AddYears(100)
        }
        else {
            $cert = $cert[0]
        }
    }

    return $cert
}

function SignPackage {
    param ([Parameter(Mandatory = $true)][System.IO.FileInfo]$path)

    &$signToolBin.FullName sign /fd SHA256 /a $path
}

if (-not(Test-Path $PackagePath)) {
    throw "$($PackagePath.FullName) not found"
}

$winSDKDir = GetWinSdkDir
$makeAppxBin = Get-Item -Path "$winSDKDir\makeappx.exe"
$signToolBin = Get-Item -Path "$winSDKDir\signtool.exe"

$signCert = GetSigningCertificate

$inputBundle = Get-Item -Path $PackagePath.FullName
$outputBundlePath = $inputBundle.FullName -replace "\.([^.]+)", "_resigned.`$1"

$tempDir = CreateEmptyDir("$(Split-Path -Parent $PSCommandPath)\Temp")
$originalPkgsDir = CreateEmptyDir("$tempDir\OriginalPkgs")
$modifiedPkgsDir = CreateEmptyDir("$tempDir\ModifiedPkgs")

&$makeAppxBin.FullName unbundle /p $inputBundle.FullName /d $originalPkgsDir.FullName
RemoveMetadata($originalPkgsDir.FullName)

foreach ($i in (Get-ChildItem -Path "$originalPkgsDir\*.appx")) {
    $dir = CreateEmptyDir("$tempDir\PkgContent")
    &$makeAppxBin.FullName unpack /p $i.FullName /d $dir.FullName
    RemoveMetadata($dir)

    $manifestFile = Get-Item -Path "$dir\AppxManifest.xml"

    $packagePublisherElement = Select-Xml -path $manifestFile.FullName -XPath "//*[local-name()='Identity']/@Publisher"
    $packagePublisherElement.Node.Value = $signCert.Subject
    $packagePublisherElement.Node.OwnerDocument.Save($manifestFile.FullName)

    &$makeAppxBin.FullName pack /d $dir.FullName /p "$modifiedPkgsDir\$($i.Name)"

    $pkg = Get-Item -Path "$modifiedPkgsDir\$($i.Name)"
    SignPackage($pkg.FullName)

    Remove-Item -Path $dir.FullName -Recurse -Force
}

&$makeAppxBin.FullName bundle /o /d $modifiedPkgsDir.FullName /p $outputBundlePath
$outputBundle = Get-Item -Path $outputBundlePath
SignPackage($outputBundle.FullName)

Remove-Item -Path $tempDir.FullName -Recurse -Force