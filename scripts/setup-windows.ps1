#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($env:OS -ne 'Windows_NT' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'This setup supports x64 Windows.'
}

$toolchain = 'stable-x86_64-pc-windows-gnu'
$cargoHomeDir = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }
$cargoBin = [IO.Path]::GetFullPath((Join-Path $cargoHomeDir 'bin'))
$rustup = Join-Path $cargoBin 'rustup.exe'
$tempDir = [IO.Directory]::CreateDirectory((Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString()))).FullName

function Get-LoginPath {
    [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Get-VerifiedDownload($Url, $Destination, $Sha256) {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $Sha256) {
        throw "SHA-256 verification failed for $Url"
    }
}

$originalPath = $env:Path
try {
    # Let rustup register Cargo's bin directory, including for an existing
    # installation whose PATH entry was removed. Rustup preserves other entries.
    $loginDirs = (Get-LoginPath) -split ';' | ForEach-Object { $_.Trim().Trim('"').TrimEnd('\') }
    if (!(Test-Path -LiteralPath $rustup -PathType Leaf) -or $cargoBin -notin $loginDirs) {
        Write-Host 'Setting up Rust for the current Windows user...'
        $url = 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-gnu/rustup-init.exe'
        $checksum = Join-Path $tempDir 'rustup-init.sha256'
        Invoke-WebRequest -UseBasicParsing -Uri "$url.sha256" -OutFile $checksum
        $installer = Join-Path $tempDir 'rustup-init.exe'
        $expectedHash = ((Get-Content -LiteralPath $checksum -Raw).Trim() -split '\s+')[0]
        Get-VerifiedDownload $url $installer $expectedHash
        & $installer -y --profile minimal --default-host x86_64-pc-windows-gnu --default-toolchain $toolchain
        if ($LASTEXITCODE -ne 0) { throw "Rust setup failed (exit $LASTEXITCODE)." }
    }

    # Check the PATH a new shell will see, not a temporary developer-shell PATH.
    $env:Path = Get-LoginPath
    $tools = 'dlltool.exe', 'as.exe'
    $missing = @($tools | Where-Object { !(Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        Write-Host "Installing $($missing -join ', ') in $cargoBin..."
        $url = 'https://github.com/skeeto/w64devkit/releases/download/v2.11.0/w64devkit-x64-2.11.0.7z.exe'
        $archive = Join-Path $tempDir 'w64devkit.7z.exe'
        Get-VerifiedDownload $url $archive '54c2bb9962e8a30c8270e34c5efc3d5fee579f53087fa7d435b95fbba2af7b2b'
        $members = @($missing | ForEach-Object { "w64devkit/bin/$_" })
        & tar.exe -xf $archive --strip-components 2 -C $tempDir @members
        if ($LASTEXITCODE -ne 0) { throw "Could not extract GNU binutils (exit $LASTEXITCODE)." }
        foreach ($name in $missing) {
            $destination = Join-Path $cargoBin $name
            try {
                [IO.File]::Move((Join-Path $tempDir $name), $destination)
            } catch [IO.IOException] {
                # Another setup process may have installed it during the download.
                if (!(Test-Path -LiteralPath $destination -PathType Leaf)) { throw }
            }
        }
    }

    & $rustup default $toolchain
    if ($LASTEXITCODE -ne 0) { throw "Could not select the Rust GNU toolchain (exit $LASTEXITCODE)." }
    & cargo.exe --version
    if ($LASTEXITCODE -ne 0) { throw 'Cargo is unavailable on the user PATH.' }

    $probe = Join-Path $tempDir 'check.exe'
    @'
#[cfg(not(all(target_arch = "x86_64", target_env = "gnu")))]
compile_error!("Run setup outside a directory or shell that overrides the Rust GNU toolchain.");
#[link(name = "kernel32", kind = "raw-dylib")]
extern "system" { fn GetCurrentProcessId() -> u32; }
fn main() { assert_ne!(unsafe { GetCurrentProcessId() }, 0); }
'@ | rustc.exe --edition 2021 --crate-name ommp_setup_check - -o $probe
    if ($LASTEXITCODE -ne 0) { throw 'The Windows GNU compile and link check failed.' }
    & $probe
    if ($LASTEXITCODE -ne 0) { throw 'The Windows GNU executable check failed.' }
    Write-Host 'Setup complete. Open a new PowerShell window and run: cargo install ommp'
} finally {
    $env:Path = $originalPath
    Get-ChildItem -LiteralPath $tempDir -File | Remove-Item -Force
    Remove-Item -LiteralPath $tempDir
}
