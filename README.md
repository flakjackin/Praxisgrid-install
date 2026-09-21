# Install PraxisGrid

Published from [flakjackin/PraxisGrid](https://github.com/flakjackin/PraxisGrid)
at version `0.3.2`. Do not edit this repository by hand -- every
file here is overwritten by that repository's `Publish installer`
workflow.

## Windows

```powershell
irm https://raw.githubusercontent.com/flakjackin/praxisgrid-install/main/install.ps1 | iex
```

Provisions WSL2 and an Ubuntu distribution if the machine has none,
installs Docker inside it, and then runs the same Linux installer a
bare Ubuntu host runs. Docker Desktop is not required.

## Ubuntu and macOS

```bash
curl -fsSL https://raw.githubusercontent.com/flakjackin/praxisgrid-install/main/install.sh | bash
```

The container images are private. The installer asks once for a
GitHub token with the `read:packages` scope and Docker stores it,
so later installs and restarts on that machine reuse it.
