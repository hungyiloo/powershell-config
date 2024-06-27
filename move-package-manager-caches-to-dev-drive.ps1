# Create packages directory on Dev Drive
$DevDrive = "D:"
$PackagesPath = "$DevDrive\packages"

if (-not (Test-Path -Path $PackagesPath))
{
  New-Item -Path $PackagesPath -ItemType "directory"
}

function Move-Item-If-Exists
{
  param (
    [string]$Path,
    [string]$Destination
  )

  if (Test-Path -Path $Path)
  {
    Write-Output "Moving $Path to $Destination..."
    Move-Item -Path $Path -Destination $Destination -Force
  } else
  {
    Write-Output "$Path doesn't exist, so not moving it."
  }
}

# Move npm packages
Move-Item-If-Exists -Path $env:LocalAppData\npm-cache -Destination $PackagesPath

# Move NuGet packages
Move-Item-If-Exists -Path $env:UserProfile\.nuget -Destination $PackagesPath

# Move cargo packages
Move-Item-If-Exists -Path $env:UserProfile\cargo -Destination $PackagesPath

# Move python/pip packages
Move-Item-If-Exists -Path $env:LocalAppData\pip -Destination $PackagesPath

# Move vcpkg packages
Move-Item-If-Exists -Path $env:LocalAppData\vcpkg -Destination $PackagesPath

# Move Maven packages
Move-Item-If-Exists -Path $env:UserProfile\.m2 -Destination $PackagesPath

# Move Gradle cache
Move-Item-If-Exists -Path $env:UserProfile\.gradle -Destination $PackagesPath

# Set configuration
Write-Output "Setting environment variables..."
[Environment]::SetEnvironmentVariable("npm_config_cache", "$PackagesPath\npm-cache", "User")
[Environment]::SetEnvironmentVariable("NUGET_PACKAGES", "$PackagesPath\.nuget\packages", "User")
[Environment]::SetEnvironmentVariable("CARGO", "$PackagesPath\cargo", "User")
[Environment]::SetEnvironmentVariable("PIP_CACHE_DIR", "$PackagesPath\pip", "User")
[Environment]::SetEnvironmentVariable("VCPKG_DEFAULT_BINARY_CACHE", "$PackagesPath\vcpkg", "User")
[Environment]::SetEnvironmentVariable("MAVEN_OPTS", "-Dmaven.repo.local=$PackagesPath\.m2 $env:MAVEN_OPTS", "User")
[Environment]::SetEnvironmentVariable("GRADLE_USER_HOME", "$PackagesPath\.gradle", "User")

Write-Output "Done "
Write-Output "You may want to restart to ensure environment variables are up to date in all contexts"
