# bootstrap

Public first-run scripts that make a machine reachable by Ansible. The
private nixos-config repo configures the machine after that (its ADR 0012).
These scripts contain no secrets. The SSH key in them is a public key.

## Windows

Install Tailscale and sign in first. Then run this in an administrator
PowerShell, with `<commit>` replaced by a commit hash from this repo:

```powershell
irm https://raw.githubusercontent.com/xentac/bootstrap/<commit>/windows.ps1 | iex
```

Use a commit hash, not `main`. The script runs with administrator rights,
and a hash makes sure that it is the version that you read. The first 12
characters of the hash are enough. Do not use fewer: GitHub also serves
commits from forks of this repo, and a fork can make a commit whose hash
starts with the same 7 characters in minutes. Over a remote desktop, paste
the command from the clipboard instead of typing it. Keep `https://`.

The script does these steps:

1. It installs and starts the OpenSSH server.
2. It allows port 22 from the tailnet only.
3. It makes PowerShell the SSH login shell.
4. It creates a hidden local administrator `ansible` and adds its public key.
5. It turns off password logins.

You can run it again. Each step checks the current state first.
