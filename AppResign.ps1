param (
    [Parameter(Mandatory = $true)][System.IO.FileInfo]$Package,
    [Parameter(Mandatory = $false)][System.IO.FileInfo]$Certificate,
    [Parameter(Mandatory = $false)][string]$CertificatePassword,
    [Parameter(Mandatory = $false)][System.IO.FileInfo]$IntermediateCertificate
)

function GetWinSdkDir {
    $dir = Get-Item -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $dir = Get-ChildItem "$dir\10.*" | Sort-Object -Descending
    $dir = $dir[0]
    $dir = Get-Item -Path "$dir\x64"
    return $dir
}

function CreateEmptyDir {
    param ([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Path)

    if (Test-Path $Path ) {
        Remove-Item -Path $Path -Recurse -Force
    }
    return New-Item -Path $Path -ItemType Directory
}

function RemoveMetadata {
    param ([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Path)

    Remove-Item -Path "$Path\AppxMetadata" -Recurse -Force
    Remove-Item -Path "$Path\AppxBlockMap.xml"
    Remove-Item -Path "$Path\AppxSignature.p7x"
}

function GetSigningCertificate {
    $cert = $null
    if ($Certificate) {
        if ($CertificatePassword) {
            $cert = Get-PfxData -FilePath $Certificate.FullName -Password (ConvertTo-SecureString -String $CertificatePassword -Force -AsPlainText)
        }
        else {
            $cert = Get-PfxData -FilePath $Certificate.FullName
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
    param ([Parameter(Mandatory = $true)][System.IO.FileInfo]$Path)

    $signArgs = @("sign", "/fd", "SHA256")
    $signArgs += @("/tr", "http://timestamp.sectigo.com", "/td", "SHA256")
    if ($IntermediateCertificate) {
        $signArgs += @("/ac", "$IntermediateCertificate")
    }

    if ($Certificate) {
        if ($CertificatePassword) {
            $signArgs += @("/f", "$Certificate", "/p", "$CertificatePassword")
        }
        else {
            $signArgs += @("/f", "$Certificate")
        }
    }
    else {
        $signArgs += $signArgs += @("/a")
    }

    $signArgs += @("$Path")
    &$signToolBin.FullName $signArgs
}

function ResignAppx {
    param ([Parameter(Mandatory = $true)][System.IO.FileInfo]$InputPackage,
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$OutputPackage,
        [Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$WorkDir
    )

    $dir = CreateEmptyDir "$WorkDir\appx"
    &$makeAppxBin.FullName unpack /p $InputPackage.FullName /d $dir.FullName
    RemoveMetadata $dir

    $manifestFile = Get-Item -Path "$dir\AppxManifest.xml"

    $packagePublisherElement = Select-Xml -path $manifestFile.FullName -XPath "//*[local-name()='Identity']/@Publisher"
    $packagePublisherElement.Node.Value = $signCert.Subject
    $packagePublisherElement.Node.OwnerDocument.Save($manifestFile.FullName)

    &$makeAppxBin.FullName pack /d $dir.FullName /p $OutputPackage.FullName
    SignPackage $OutputPackage.FullName

    Remove-Item -Path $dir.FullName -Recurse -Force
}

function ResignAppxBundle {
    param ([Parameter(Mandatory = $true)][System.IO.FileInfo]$InputPackage,
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$OutputPackage,
        [Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$WorkDir
    )

    $originalPkgsDir = CreateEmptyDir "$WorkDir\appxbundle_original"
    $modifiedPkgsDir = CreateEmptyDir "$WorkDir\appxbundle_resigned"

    &$makeAppxBin.FullName unbundle /p $InputPackage.FullName /d $originalPkgsDir.FullName
    RemoveMetadata $originalPkgsDir.FullName

    foreach ($i in (Get-ChildItem -Path "$originalPkgsDir\*.appx")) {
        ResignAppx $i ([System.IO.FileInfo]("$modifiedPkgsDir\$($i.Name)")) $WorkDir
    }

    &$makeAppxBin.FullName bundle /o /d $modifiedPkgsDir.FullName /p $OutputPackage.FullName
    SignPackage $OutputPackage.FullName

    Remove-Item -Path $originalPkgsDir.FullName -Recurse -Force
    Remove-Item -Path $modifiedPkgsDir.FullName -Recurse -Force
}

if (-not($Package.Exists)) {
    throw "$($Package.FullName) not found"
}

$winSDKDir = GetWinSdkDir
$makeAppxBin = Get-Item -Path "$winSDKDir\makeappx.exe"
$signToolBin = Get-Item -Path "$winSDKDir\signtool.exe"

$signCert = GetSigningCertificate
$tempDir = CreateEmptyDir "$(Split-Path -Parent $PSCommandPath)\_appxresigner_workdir"
$outPackage = [System.IO.FileInfo]($Package.FullName -replace "\.([^.]+)", "_resigned.`$1")

if ($Package.Extension -eq ".appx") {
    ResignAppx $Package $outPackage $tempDir
}
elseif ($Package.Extension -eq ".appxbundle") {
    ResignAppxBundle  $Package $outPackage $tempDir
}
else {
    throw "$($Package.FullName) unsupported"
}

Remove-Item -Path $tempDir.FullName -Recurse -Force